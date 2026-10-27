import AXKit
import ControlCore
import Foundation
import WeComAdapter

/// Drives `WatchEngine` from the main run loop: a fallback poll timer, AX
/// notifications (debounced) when `observe` is on, persistence of drafts,
/// the `system` pause on client loss, and the state file.
final class DaemonWatcher {
    private let store: ControlStore
    private let backend: AXBackend
    private let bundleID: String
    /// Socket path served by this daemon (reported in the state file so the console finds it).
    var socketPath: String?
    private let engine: WatchEngine
    private let interval: Double
    private let observe: Bool
    private let debounce: Double
    private let policyProvider: PolicyProvider
    private let statePath: URL
    private let log: DaemonLog
    private var pollTimer: Timer?
    private var stateTimer: Timer?
    private var pendingPoll: Timer?
    /// The visual fallback may pump the main run loop while waiting for a
    /// single-frame callback. Queue one follow-up instead of reentering the
    /// engine or dropping an AX notification that arrived meanwhile.
    private var polling = false
    private var deferredPoll = false
    private var subscription: WeComObserverSubscription?
    private var lastPollMs: Int64 = 0
    private var notifications = 0
    private var lastNotificationMs: Int64 = 0
    private var burstStartedMs: Int64 = 0
    private var observedViaNotification = 0
    /// nil = not yet known; toggles the `system` pause reason on transitions.
    private var clientAvailable: Bool?
    /// Transient read failures (a pane the client does not expose) do not pause at once.
    private var availability = AvailabilityTracker()
    /// Contact-request rounds, triggered by the 通讯录 badge (B7).
    var automation: RequestAutomation?
    /// Last logged rail reading problem: `.none` before the first poll, `.some(nil)` once the badge was attributed.
    private var loggedRailProblem: String?? = .none
    private let startedMs = Clock.nowMs()
    /// B10: shared with the command handler; nil in tests.
    var mediaIndex: MediaIndex?
    /// B52: the latest poll for controller.readiness.
    let health: WatchHealth
    /// B61: times each poll and puts the AX summary into the state file; nil in tests.
    var axReporter: AXTimingReporter?

    init(store: ControlStore, bundleID: String, backend: AXBackend, interval: Double, observe: Bool, debounce: Double,
         policyProvider: PolicyProvider, statePath: URL, log: DaemonLog, health: WatchHealth = WatchHealth()) {
        self.health = health
        self.store = store; self.backend = backend; self.bundleID = bundleID
        self.interval = interval; self.observe = observe; self.debounce = debounce
        self.policyProvider = policyProvider; self.statePath = statePath; self.log = log
        engine = WatchEngine(
            readerProvider: { try WeComReader(window: try WeComWindowLocator.mainWindow(from: try AXApp.byBundleID(bundleID, backend: backend))) },
            recentSends: { (try? store.recentSends(sinceMs: Clock.nowMs() - 600_000)) ?? [] }
        )
        engine.identityLookup = { (try? store.identities(title: $0)) ?? [] }
        engine.onRelocated = { [weak self] layout in self?.subscribe(layout) }
    }

    func start() {
        poll(trigger: "start")
        if interval > 0 {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll(trigger: "timer") }
            RunLoop.main.add(t, forMode: .default)
            pollTimer = t
        }
        let s = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.writeState() }
        RunLoop.main.add(s, forMode: .default)
        stateTimer = s
        writeState()
    }

    func stop() {
        pollTimer?.invalidate()
        stateTimer?.invalidate()
        pendingPoll?.invalidate()
        subscription?.observer.stop()
        subscription = nil
    }

    // MARK: Polling

    private func poll(trigger: String) {
        if polling { deferredPoll = true; return }
        polling = true
        defer {
            polling = false
            if deferredPoll {
                deferredPoll = false
                DispatchQueue.main.async { [weak self] in self?.poll(trigger: "deferred") }
            }
        }
        // `imctl policy` edits the file from another process; pick it up on the
        // timer path only, so a burst of AX notifications never stats the file.
        if trigger == "timer" || trigger == "start", let changed = policyProvider.reloadIfChanged() {
            let payload = ["policy": changed.summary, "policyFile": policyProvider.url.path]
            do { try store.appendEvent(kind: .controllerState, payloadJSON: json(payload), nowMs: Clock.nowMs()) }
            catch { log.info("failed to record policy change: \(error)") }
            log.info("policy reloaded: \(changed.summary)")
        } else if let problem = policyProvider.lastError, trigger == "timer", engine.polls % 300 == 0 {
            log.info("WARNING: policy file unreadable, last good policy kept: \(problem)")
        }
        let drafts: [WatchDraft]
        let pollStarted = DispatchTime.now().uptimeNanoseconds
        do {
            // An AX notification is direct evidence that content may have
            // changed in place even if row handles and the preview did not.
            drafts = try engine.poll(forceMessages: trigger.hasPrefix("ax:"))
            axReporter?.timings.recordScope(AXTimingReporter.pollScope, nanos: DispatchTime.now().uptimeNanoseconds - pollStarted, ok: true)
            lastPollMs = Clock.nowMs()
        } catch {
            axReporter?.timings.recordScope(AXTimingReporter.pollScope, nanos: DispatchTime.now().uptimeNanoseconds - pollStarted, ok: false)
            subscription?.observer.stop()
            subscription = nil
            let verdict = Self.availabilityVerdict(after: error,
                                                   rootProvider: { try AXApp.byBundleID(bundleID, backend: backend) },
                                                   tracker: &availability)
            if verdict != .available { health.noteError(nowMs: Clock.nowMs()) }
            if verdict != .available, engine.errors % 60 == 1 {
                log.info("watcher error (\(engine.errors)): \(error)")
            }
            switch verdict {
            case .available:
                // The watcher has no chat table while the user is on the
                // Contacts tab, but the client remains reachable. Commands
                // must be able to navigate out of that tab.
                setClientAvailable(true, reason: nil)
            case .unavailable(let reason):
                setClientAvailable(false, reason: reason)
            case .degraded(let count):
                if count == 1 { log.info("watcher degraded: \(error) (system pause after \(availability.threshold) consecutive failures)") }
            }
            health.update { $0.lastPollMs = Clock.nowMs(); $0.lastPollOK = false }
            return
        }
        _ = availability.succeeded()
        let railProblem = engine.newCustomersBadgeProblem
        if loggedRailProblem != .some(railProblem) {
            // An unattributed badge is not fed to the trigger, so no automatic request round starts on a guess; say why once per change.
            log.info(railProblem.map { "rail: 通讯录 badge unknown (\($0)); automatic request rounds wait for a recognised rail" }
                     ?? "rail: 通讯录 badge attributed")
            loggedRailProblem = .some(railProblem)
        }
        automation?.noteBadge(railProblem == nil ? engine.newCustomersBadge : nil)
        let conversations = engine.conversationCount
        health.update {
            $0.lastPollMs = Clock.nowMs(); $0.lastPollOK = true; $0.conversationCount = conversations
            $0.railRead = true; $0.railProblem = railProblem
        }
        for draft in drafts {
            do { try store.appendEvent(kind: draft.kind, payloadJSON: json(draft.payload), nowMs: Clock.nowMs()) }
            catch { log.info("failed to record \(draft.kind.rawValue): \(error)") }
            // B10: remember when a picture row was first seen so message.media can find its cache file later
            // (B13: file / video rows carry the same observation bookkeeping). The row's own labels travel with
            // it (2026-09-23): message.media matches a file by name and size, and a video reports its duration,
            // so recording them here is what lets it answer without reading the rows back from the client.
            if draft.kind == .messageObserved,
               let rowKind = draft.payload["kind"],
               [MessageRowKind.media.rawValue, MessageRowKind.file.rawValue, MessageRowKind.video.rawValue].contains(rowKind),
               let key = draft.payload["messageKey"] {
                mediaIndex?.observe(messageKey: key, conversation: draft.payload["conversation"] ?? "", direction: draft.payload["direction"] ?? "",
                                    kind: rowKind, fileName: draft.payload["fileName"], fileSize: draft.payload["fileSize"],
                                    duration: draft.payload["duration"], nowMs: Clock.nowMs())
            }
        }
        if !drafts.isEmpty, trigger.hasPrefix("ax:") {
            observedViaNotification += drafts.count
            log.info("observer: \(drafts.count) event(s) via \(trigger) in \(Clock.nowMs() - burstStartedMs) ms")
        }
        setClientAvailable(true, reason: nil)
    }

    // MARK: AXObserver

    private func subscribe(_ layout: WeComLayout) {
        subscription?.observer.stop()
        subscription = nil
        guard observe else { return }
        do {
            let sub = try WeComObserver.subscribe(to: layout) { [weak self] event in self?.handle(event) }
            subscription = sub
            let extra = sub.unsupported.isEmpty ? "" : " (unsupported: \(sub.unsupported.joined(separator: ",")))"
            log.info("observer: subscribed \(sub.added) notifications\(extra)")
        } catch {
            log.info("observer: subscribe failed: \(error)")
        }
    }

    /// Notifications arrive on the main run loop in bursts; coalesce them and
    /// poll once shortly after the last one.
    private func handle(_ event: AXNotificationEvent) {
        notifications += 1
        let now = Clock.nowMs()
        lastNotificationMs = now
        if pendingPoll == nil { burstStartedMs = now }
        pendingPoll?.invalidate()
        let t = Timer(timeInterval: debounce, repeats: false) { [weak self] _ in
            self?.pendingPoll = nil
            self?.poll(trigger: "ax:\(event.name)")
        }
        RunLoop.main.add(t, forMode: .default)
        pendingPoll = t
    }

    // MARK: Availability

    /// `conversationTable` is absent by design on 通讯录. Distinguish that
    /// specific, reachable pane — in the main window or, while another client
    /// window stands in front of it, in a window behind — from loss of the app
    /// or main window. Other watcher failures keep the existing
    /// consecutive-failure policy.
    static func availabilityVerdict(after error: Error,
                                    rootProvider: () throws -> AXElement,
                                    tracker: inout AvailabilityTracker) -> AvailabilityTracker.Verdict {
        guard let viewError = error as? WeComError,
              case .region("conversationTable") = viewError else {
            return tracker.failed(error)
        }
        do {
            let app = try rootProvider()
            guard app.backend.isProcessTrusted(prompt: false) else { throw AXKitError.notTrusted }
            guard try app.role() == AXRole.application else { throw WeComError.noWindow }
            let window = try WeComWindowLocator.mainWindow(from: app)
            guard try window.role() == AXRole.window,
                  try app.pid() > 0,
                  try window.pid() == app.pid(),
                  let frame = try window.frame(),
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0,
                  frame.width <= 10_000, frame.height <= 10_000 else {
                throw WeComError.noWindow
            }
            if Self.isContactsPane(window: window) { return tracker.succeeded() }
            // Live 2026-09-29: another client window in front — such as the 添加客户 panel or
            // the 发送验证申请 window a command opens on 通讯录 — is the app's main window (the
            // newest, listed first) while the window behind it still shows the contacts pane.
            if try app.elements(AXAttribute.windows).contains(where: {
                $0.handle != window.handle && Self.isContactsPane(window: $0)
            }) {
                return tracker.succeeded()
            }
            return tracker.failed(error)
        } catch {
            // A missing app, missing window or AX trust failure is hard;
            // intermittent AX reads keep AvailabilityTracker's threshold.
            return tracker.failed(error)
        }
    }

    private static func isContactsPane(window: AXElement) -> Bool {
        guard WeComContactsView.isShowing(window: window) else { return false }
        let outlines = window.descendants(maxDepth: 10, maxNodes: 3_000)
            .filter { (try? $0.role()) == AXRole.outline && (try? $0.isSettable(AXAttribute.selectedRows)) == true }
        let matches = outlines.flatMap { outline -> [AXElement] in
            ((try? outline.children()) ?? []).filter { row in
                guard (try? row.role()) == AXRole.row else { return false }
                return row.descendants(maxDepth: 3, maxNodes: 50).contains { child in
                    guard let role = try? child.role(),
                          [AXRole.staticText, AXRole.textArea, AXRole.textField].contains(role) else { return false }
                    return (try? child.valueString()) == WeComContactsView.newCustomersTitle
                }
            }
        }
        return matches.count == 1
    }

    /// Client unreachable (not running, no window, AX failing) = `system` pause;
    /// reachable again = pause lifted. Both transitions are `controller.state` events.
    private func setClientAvailable(_ available: Bool, reason: String?) {
        guard clientAvailable != available else { return }
        clientAvailable = available
        health.update { $0.clientAvailable = available }
        do {
            try store.setPause(.system, on: !available, nowMs: Clock.nowMs())
            let reasons = (try? store.pauseReasons().map(\.rawValue)) ?? []
            // Same shape as controller.pause/resume: `paused` is an array, `clientAvailable` a bool.
            var payload: [String: Any] = ["paused": reasons, "clientAvailable": available]
            if let reason { payload["reason"] = reason }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try store.appendEvent(kind: .controllerState, payloadJSON: String(decoding: data, as: UTF8.self), nowMs: Clock.nowMs())
            log.info(available ? "client available; system pause lifted" : "client unavailable; system pause set (\(reason ?? "-"))")
        } catch {
            log.info("failed to record client availability: \(error)")
        }
    }

    // MARK: State file

    private func writeState() {
        var state: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "startedMs": startedMs, "lastPollMs": lastPollMs, "polls": engine.polls, "errors": engine.errors, "relocations": engine.relocations,
            "active": engine.active ?? "", "conversations": engine.conversationCount,
            "observer": subscription != nil, "notifications": notifications, "lastNotificationMs": lastNotificationMs,
            "observedViaNotification": observedViaNotification,
            "version": IMCTLVersion.string,
            "policy": policyProvider.current().summary,
            // The daemon's own grant (under launchd nothing is inherited); the console shows it.
            "trusted": backend.isProcessTrusted(prompt: false),
            "socket": socketPath ?? "",
            "newCustomersBadge": engine.newCustomersBadge,
            "newCustomersBadgeProblem": engine.newCustomersBadgeProblem ?? "",
        ]
        state["paused"] = (try? store.pauseReasons().map(\.rawValue)) ?? []
        state["lastEventId"] = (try? store.lastEventId()) ?? 0
        if let axReporter {
            state["ax"] = axReporter.stateSummary()
            axReporter.tick()
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: statePath, options: .atomic)
        }
    }

    private func json(_ dict: [String: String]) -> String {
        (try? JSONValueLite.serialize(dict)) ?? "{}"
    }
}

enum JSONValueLite {
    static func serialize(_ dict: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]), as: UTF8.self)
    }
}
