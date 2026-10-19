import ControlCore
import CryptoKit
import Foundation
import WeComAdapter

/// One round per trigger (`RequestRoundTrigger`: badge change, automation
/// switched on, daemon start, half-hour sweep, retry): read the cards through
/// the executor (so every step is a command with records and events), report
/// new ones, accept per policy, and create one group per accepted person when
/// asked to. Runs off the main run loop; the executor serialises it with
/// everything else.
final class RequestAutomation {
    let executor: CommandExecutor
    let policyProvider: PolicyProvider
    let store: ControlStore
    let log: DaemonLog
    /// Scheduling state (pure, tested in WeComAdapterTests); touched under `lock`.
    var trigger = RequestRoundTrigger()
    static let seenKey = "requests.seen"

    private let queue = DispatchQueue(label: "com.sunkailun.imctl.requests")
    private let lock = NSLock()

    init(executor: CommandExecutor, policyProvider: PolicyProvider, store: ControlStore, log: DaemonLog) {
        self.executor = executor; self.policyProvider = policyProvider; self.store = store; self.log = log
    }

    /// Called after every successful poll with the 通讯录 badge count (nil
    /// while the rail cannot be attributed); the trigger decides whether a
    /// round starts now.
    func noteBadge(_ badge: Int?) {
        let policy = policyProvider.current().contactRequests
        lock.lock()
        let reason = trigger.poll(badge: badge, mode: policy.autoAccept, nowMs: Clock.nowMs())
        lock.unlock()
        guard let reason else { return }
        log.info("requests: round (\(reason.rawValue), badge \(badge.map(String.init) ?? "unknown"), \(policy.summary))")
        queue.async { [self] in
            var ok = false
            defer { lock.lock(); trigger.finished(success: ok, nowMs: Clock.nowMs()); lock.unlock() }
            do { ok = try runRound(policy: policy) } catch { log.info("requests: round failed: \(error)") }
        }
    }

    /// True when the cards were read; accept / group outcomes are logged per name.
    @discardableResult
    func runRound(policy: ContactRequestPolicy) throws -> Bool {
        let list = try executor.submit(method: .contactRequestList, paramsJSON: "{}", idempotencyKey: nil, origin: .automation)
        guard list.state == .succeeded, let json = list.resultJSON,
              let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else {
            log.info("requests: list \(list.state.rawValue) \(list.errorCode ?? "")\(list.errorMessage.map { ": \($0)" } ?? "")")
            return false
        }
        let cards = rows.map { (name: $0["name"] ?? "", greeting: $0["greeting"], status: $0["status"] ?? "") }
        let stored = (try? store.value(forKey: Self.seenKey)) ?? nil
        let seenBefore = Set(stored.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
        let plan = RequestDecision.plan(cards: cards, policy: policy, seen: seenBefore)
        for name in plan.observe {
            guard let card = rows.first(where: { $0["name"] == name }) else { continue }
            let payload = try JSONSerialization.data(withJSONObject: card, options: [.sortedKeys])
            try store.appendEvent(kind: .contactRequestObserved, payloadJSON: String(decoding: payload, as: UTF8.self), nowMs: Clock.nowMs())
        }
        let seen = Array(plan.seen.sorted().suffix(500))
        try store.setValue(String(decoding: try JSONEncoder().encode(seen), as: UTF8.self), forKey: Self.seenKey)
        log.info("requests: \(cards.count) card(s), \(plan.observe.count) new, \(plan.accept.count) to accept (\(policy.summary))")

        for name in plan.accept {
            let greeting = cards.first { $0.name == name }?.greeting
            let digest = SHA256.hash(data: Data(RequestDecision.key(name: name, greeting: greeting).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let acceptBase = "auto-accept-\(digest)"
            let acceptKey = RequestDecision.attemptKey(base: acceptBase, previous: (try? store.command(idempotencyKey: acceptBase))?.state, nowMs: Clock.nowMs())
            let acceptParams = try JSONSerialization.data(withJSONObject: ["name": name, "idempotencyKey": acceptKey], options: [.sortedKeys])
            let accept = try executor.submit(method: .contactRequestAccept, paramsJSON: String(decoding: acceptParams, as: UTF8.self), idempotencyKey: acceptKey, origin: .automation)
            log.info("requests: accept (\(name.count) chars) -> \(accept.state.rawValue) \(accept.errorCode ?? "")")
            guard accept.state == .succeeded, policy.autoGroup == .perPerson else { continue }
            let members = [name] + policy.groupDefaultMembers
            guard members.count >= 2 else {
                log.info("requests: no group for (\(name.count) chars): groupDefaultMembers is empty and the client opens a direct chat for one member")
                continue
            }
            let groupBase = "auto-group-\(digest)"
            let groupKey = RequestDecision.attemptKey(base: groupBase, previous: (try? store.command(idempotencyKey: groupBase))?.state, nowMs: Clock.nowMs())
            let groupParams = try JSONSerialization.data(withJSONObject: [
                "members": members, "name": policy.groupName(for: name), "idempotencyKey": groupKey,
            ] as [String: Any], options: [.sortedKeys])
            let group = try executor.submit(method: .groupCreate, paramsJSON: String(decoding: groupParams, as: UTF8.self), idempotencyKey: groupKey, origin: .automation)
            log.info("requests: group for (\(name.count) chars) -> \(group.state.rawValue) \(group.errorCode ?? "")")
        }
        return true
    }
}
