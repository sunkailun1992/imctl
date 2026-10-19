import AXKit
import Darwin
import Foundation
import WeComAdapter

struct WatchSummary: Codable {
    var seconds: Double
    var polls: Int
    var events: Int
    var notifications: [String: Int]
    var relocations: Int
    var errors: Int
    var lockChanges: Int
    var cpuUserSeconds: Double
    var cpuSystemSeconds: Double
    var maxPollMs: Double
    var meanPollMs: Double

    func render() -> String {
        let notes = notifications.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return """
        watch: seconds=\(Int(seconds)) polls=\(polls) events=\(events) relocations=\(relocations) errors=\(errors) lock_changes=\(lockChanges)
        cpu: user=\(String(format: "%.2f", cpuUserSeconds))s sys=\(String(format: "%.2f", cpuSystemSeconds))s
        poll_ms: max=\(String(format: "%.0f", maxPollMs)) mean=\(String(format: "%.0f", meanPollMs))
        notifications: \(notes.isEmpty ? "-" : notes)
        """
    }
}

/// Polling diff + AXObserver notifications over one WeCom window. Every line
/// printed is also appended to the JSONL log (redacted) when `log` is set.
final class WatchRunner {
    enum Mode: String { case both, poll, observer }

    private let options: ProbeOptions
    private let seconds: Double
    private let interval: Double
    private let mode: Mode
    private let logURL: URL?
    private let redact: (String?) -> String?

    private var reader: WeComReader
    private var previous: WatchSnapshot
    private var observer: AXObserving?
    private var summary: WatchSummary
    private var pollDurations: [Double] = []
    private var lastLocked: Bool?
    private var pendingPoll: Timer?
    private var logHandle: FileHandle?
    private let iso = ISO8601DateFormatter()

    init(options: ProbeOptions, seconds: Double, interval: Double, mode: Mode, log: String?) throws {
        self.options = options
        self.seconds = seconds
        self.interval = interval
        self.mode = mode
        self.logURL = log.map { URL(fileURLWithPath: $0) }
        self.redact = ProbeSession.redactor(options)
        self.reader = try ProbeSession.reader(options)
        self.previous = Self.redacted(try WatchSnapshot.take(reader), redact)
        self.summary = WatchSummary(seconds: seconds, polls: 1, events: 0, notifications: [:], relocations: 0, errors: 0,
                                    lockChanges: 0, cpuUserSeconds: 0, cpuSystemSeconds: 0, maxPollMs: 0, meanPollMs: 0)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func run() throws -> WatchSummary {
        if let logURL {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            logHandle = try FileHandle(forWritingTo: logURL)
            logHandle?.seekToEndOfFile()
        }
        emit(source: "start", fields: ["mode": mode.rawValue, "interval": String(interval), "seconds": String(seconds),
                                       "conversations": String(previous.conversations.count), "messages": String(previous.messages.count),
                                       "active": previous.active ?? "-"])
        lastLocked = HostProbe.screenLocked()
        if mode != .poll, options.fromFixture == nil { subscribe() }

        if seconds > 0 {
            let pollTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll(trigger: "timer") }
            RunLoop.main.add(pollTimer, forMode: .default)
            let stop = Timer(timeInterval: seconds, repeats: false) { _ in CFRunLoopStop(CFRunLoopGetMain()) }
            RunLoop.main.add(stop, forMode: .default)
            CFRunLoopRun()
            pollTimer.invalidate()
        } else {
            poll(trigger: "once")
        }
        observer?.stop()

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        summary.cpuUserSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        summary.cpuSystemSeconds = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        summary.maxPollMs = pollDurations.max() ?? 0
        summary.meanPollMs = pollDurations.isEmpty ? 0 : pollDurations.reduce(0, +) / Double(pollDurations.count)
        emit(source: "summary", fields: ["polls": String(summary.polls), "events": String(summary.events), "errors": String(summary.errors)])
        try? logHandle?.close()
        return summary
    }

    // MARK: Polling

    private func poll(trigger: String) {
        let started = Date()
        do {
            let snapshot = Self.redacted(try WatchSnapshot.take(reader), redact)
            let events = WatchDiff.compare(previous, snapshot)
            previous = snapshot
            for event in events {
                summary.events += 1
                emit(source: "poll", fields: ["trigger": trigger, "event": event.summary])
            }
        } catch {
            summary.errors += 1
            emit(source: "error", fields: ["trigger": trigger, "error": String(describing: error)])
            relocate()
        }
        let ms = Date().timeIntervalSince(started) * 1000
        pollDurations.append(ms)
        summary.polls += 1
        let locked = HostProbe.screenLocked()
        if locked != lastLocked {
            summary.lockChanges += 1
            emit(source: "lock", fields: ["screen_locked": locked.map(String.init) ?? "unknown"])
            lastLocked = locked
        }
    }

    private func relocate() {
        do {
            reader = try ProbeSession.reader(options)
            summary.relocations += 1
            emit(source: "relocate", fields: ["ok": "true"])
            if mode != .poll, options.fromFixture == nil { subscribe() }
        } catch {
            emit(source: "relocate", fields: ["ok": "false", "error": String(describing: error)])
        }
    }

    // MARK: Observer

    private func subscribe() {
        observer?.stop()
        observer = nil
        do {
            let sub = try WeComObserver.subscribe(to: reader.layout) { [weak self] event in self?.handle(event) }
            observer = sub.observer
            emit(source: "subscribe", fields: ["added": String(sub.added), "unsupported": sub.unsupported.joined(separator: ",")])
        } catch {
            emit(source: "subscribe", fields: ["error": String(describing: error)])
        }
    }

    private func handle(_ event: AXNotificationEvent) {
        summary.notifications[event.name, default: 0] += 1
        let element = AXElement(handle: event.element, backend: reader.layout.window.backend)
        let role = (try? element.role()) ?? "?"
        emit(source: "ax", fields: ["name": event.name, "role": role])
        // Coalesce bursts, then diff right away to measure notification -> observation latency.
        pendingPoll?.invalidate()
        let t = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in self?.poll(trigger: "ax:\(event.name)") }
        RunLoop.main.add(t, forMode: .default)
        pendingPoll = t
    }

    // MARK: Output

    private func emit(source: String, fields: [String: String]) {
        let t = iso.string(from: Date())
        let line = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("\(t) \(source) \(line)")
        fflush(stdout)
        guard let logHandle else { return }
        var record = fields
        record["t"] = t
        record["source"] = source
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            logHandle.write(data)
            logHandle.write(Data("\n".utf8))
        }
    }

    private static func redacted(_ s: WatchSnapshot, _ redact: (String?) -> String?) -> WatchSnapshot {
        var out = s
        out.active = redact(s.active)
        out.conversations = s.conversations.map { c in
            var c = c
            c.title = redact(c.title); c.preview = redact(c.preview); c.badge = redact(c.badge)
            return c
        }
        out.messages = s.messages.map { m in
            var m = m
            m.text = redact(m.text)
            return m
        }
        return out
    }
}
