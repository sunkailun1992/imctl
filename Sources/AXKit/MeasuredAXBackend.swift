import Foundation

/// B61: wraps any `AXBackend` and times every call that crosses into the client
/// process, recording it in `timings`. Errors and handles pass through unchanged
/// and `name` is the wrapped backend's, so callers behave exactly as before.
/// Calls that stay local (trust check, creating the application element or an
/// observer) are forwarded untimed.
public final class MeasuredAXBackend: AXBackend {
    public let base: AXBackend
    public let timings: AXCallTimings
    /// false: nothing is batched and each attribute is read (and timed) on access, as
    /// before batching existed, so a probe can compare both ways on the same client.
    public let batchReads: Bool
    public var slowCallThresholdMs: Double = 1000
    /// Called after a timed call that took at least `slowCallThresholdMs`.
    public var onSlowCall: ((AXCallSample) -> Void)?

    private let now: () -> UInt64
    private let wallMs: () -> Int64
    private let threadLabel: () -> String

    public init(base: AXBackend, timings: AXCallTimings, batchReads: Bool = true,
                now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                wallMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                threadLabel: @escaping () -> String = MeasuredAXBackend.currentThreadLabel) {
        self.base = base
        self.timings = timings
        self.batchReads = batchReads
        self.now = now
        self.wallMs = wallMs
        self.threadLabel = threadLabel
    }

    public var name: String { base.name }

    public func isProcessTrusted(prompt: Bool) -> Bool { base.isProcessTrusted(prompt: prompt) }

    public func applicationElement(pid: pid_t) -> AXElementHandle { base.applicationElement(pid: pid) }

    public func attributeNames(of element: AXElementHandle) throws -> [String] {
        try timed(.attributeNames, "") { try base.attributeNames(of: element) }
    }

    public func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? {
        try timed(.get, name, outcome: { $0 == nil ? "noValue" : "ok" }) { try base.attribute(name, of: element) }
    }

    public func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult] {
        // Nothing batched: the snapshot reads each attribute on access, through this backend.
        guard batchReads else { return [:] }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return try timed(.getMany, unique.joined(separator: ","),
                         outcome: { $0.isEmpty && !unique.isEmpty ? "fallback" : "ok" },
                         items: Self.itemOutcomes) {
            try base.attributes(names, of: element)
        }
    }

    public func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool {
        try timed(.isSettable, name) { try base.isAttributeSettable(name, of: element) }
    }

    public func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws {
        try timed(.set, name) { try base.setAttribute(name, to: value, of: element) }
    }

    public func actionNames(of element: AXElementHandle) throws -> [String] {
        try timed(.actionNames, "") { try base.actionNames(of: element) }
    }

    public func performAction(_ name: String, on element: AXElementHandle) throws {
        try timed(.perform, name) { try base.performAction(name, on: element) }
    }

    public func pid(of element: AXElementHandle) throws -> pid_t {
        try timed(.pid, "") { try base.pid(of: element) }
    }

    public func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try base.makeObserver(pid: pid, handler: handler)
    }

    /// `main` on the main queue, otherwise the current dispatch queue's label
    /// (the executor, socket and readiness queues are labelled). GCD's global
    /// queues and plain threads report `com.apple.root.*`; those read `other`.
    public static func currentThreadLabel() -> String {
        let label = String(cString: __dispatch_queue_get_label(nil))
        if label == "com.apple.main-thread" { return "main" }
        if label.hasPrefix("com.apple.root.") { return "other" }
        if !label.isEmpty { return label }
        return Thread.isMainThread ? "main" : "other"
    }

    // MARK: Recording

    private func timed<T>(_ operation: AXCallOperation, _ name: String,
                          outcome: (T) -> String = { _ in "ok" },
                          items: ([String: AXAttributeResult]) -> [String: Int] = { _ in [:] },
                          _ body: () throws -> T) throws -> T {
        let start = now()
        do {
            let value = try body()
            record(operation, name, start: start, outcome: outcome(value),
                   items: (value as? [String: AXAttributeResult]).map(items) ?? [:])
            return value
        } catch {
            record(operation, name, start: start, outcome: AXCallTimings.outcomeLabel(for: error), items: [:])
            throw error
        }
    }

    private func record(_ operation: AXCallOperation, _ name: String, start: UInt64, outcome: String, items: [String: Int]) {
        let end = now()
        let sample = AXCallSample(atMs: wallMs(), operation: operation, name: name,
                                  nanos: end >= start ? end - start : 0, outcome: outcome,
                                  thread: threadLabel(), itemOutcomes: items)
        timings.record(sample)
        if Double(sample.nanos) / 1_000_000 >= slowCallThresholdMs { onSlowCall?(sample) }
    }

    /// Per-attribute results that carried no value, as `item:<label>` counts.
    static func itemOutcomes(_ results: [String: AXAttributeResult]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for result in results.values {
            switch result {
            case .success(.some): continue
            case .success(.none): counts["item:noValue", default: 0] += 1
            case .failure(let error): counts["item:" + AXCallTimings.outcomeLabel(for: error), default: 0] += 1
            }
        }
        return counts
    }
}
