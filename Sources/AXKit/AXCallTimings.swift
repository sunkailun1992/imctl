import Foundation

/// The AX primitive a timed call went through. `getMany` is one batched read
/// (`AXUIElementCopyMultipleAttributeValues`), however many attributes it carried.
public enum AXCallOperation: String, Codable, CaseIterable {
    case get, getMany, attributeNames, isSettable, set, actionNames, perform, pid
}

/// One timed AX call. It carries the primitive, the AX attribute or action
/// name, the duration, a fixed outcome label and the calling thread's label;
/// never a value read from the client.
public struct AXCallSample: Equatable, Codable {
    public var atMs: Int64
    public var operation: AXCallOperation
    /// AX attribute or action name; a batched read joins its names with ",".
    public var name: String
    public var nanos: UInt64
    /// `ok`, `noValue` or an `AXCallTimings.outcomeLabel(for:)` label.
    public var outcome: String
    public var thread: String
    /// Batched reads only: per-attribute results other than a value, as `item:<label>` counts.
    public var itemOutcomes: [String: Int]

    public init(atMs: Int64, operation: AXCallOperation, name: String, nanos: UInt64,
                outcome: String = "ok", thread: String = "main", itemOutcomes: [String: Int] = [:]) {
        self.atMs = atMs
        self.operation = operation
        self.name = name
        self.nanos = nanos
        self.outcome = outcome
        self.thread = thread
        self.itemOutcomes = itemOutcomes
    }
}

/// Snapshot of `AXCallTimings`. Percentiles are histogram bucket upper bounds,
/// capped at the observed maximum; milliseconds keep one decimal.
public struct AXCallTimingReport: Equatable, Codable {
    public struct Operation: Equatable, Codable {
        public var operation: String
        public var name: String
        public var count: Int
        public var totalMs: Double
        public var maxMs: Double
        public var p50Ms: Double
        public var p95Ms: Double
        public var p99Ms: Double
        /// Call outcomes, plus `item:<label>` counts for batched reads.
        public var outcomes: [String: Int]
    }

    public struct Thread: Equatable, Codable {
        public var thread: String
        public var count: Int
        public var totalMs: Double
        public var maxMs: Double
    }

    /// A span the caller timed around many AX calls (the daemon's watcher polls).
    public struct Scope: Equatable, Codable {
        public var name: String
        public var count: Int
        public var failures: Int
        public var totalMs: Double
        public var maxMs: Double
        public var p50Ms: Double
        public var p95Ms: Double
        public var p99Ms: Double
    }

    public var sinceMs: Int64
    public var generatedMs: Int64
    public var calls: Int
    public var totalMs: Double
    /// Calls that ended in `cannotComplete` (the target did not answer within the messaging timeout).
    public var timeouts: Int
    public var slowCalls: Int
    public var slowThresholdMs: Double
    /// Sorted by total time, longest first.
    public var operations: [Operation]
    public var threads: [Thread]
    public var scopes: [Scope]
    /// The newest slow calls, oldest first.
    public var slowSamples: [AXCallSample]
}

/// Thread-safe aggregation of `AXCallSample`s for one process. Memory stays
/// bounded: keys are AX attribute / action names from code, and only the
/// newest `keepSlowSamples` slow calls are kept.
public final class AXCallTimings {
    /// Histogram bucket upper bounds in milliseconds; one more bucket holds everything above the last.
    public static let bucketUpperBoundsMs: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000]

    public let slowThresholdMs: Double
    public let keepSlowSamples: Int

    private struct Histogram {
        var count = 0
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0
        var buckets = [Int](repeating: 0, count: AXCallTimings.bucketUpperBoundsMs.count + 1)

        mutating func add(_ nanos: UInt64) {
            count += 1
            totalNanos &+= nanos
            maxNanos = max(maxNanos, nanos)
            let ms = Double(nanos) / 1_000_000
            let index = AXCallTimings.bucketUpperBoundsMs.firstIndex { ms <= $0 } ?? AXCallTimings.bucketUpperBoundsMs.count
            buckets[index] += 1
        }

        func percentileMs(_ q: Double) -> Double {
            guard count > 0 else { return 0 }
            let target = max(1, Int((q * Double(count)).rounded(.up)))
            let maxMs = AXCallTimings.milliseconds(maxNanos)
            var cumulative = 0
            for (index, n) in buckets.enumerated() {
                cumulative += n
                guard cumulative >= target else { continue }
                let bounds = AXCallTimings.bucketUpperBoundsMs
                return index < bounds.count ? min(bounds[index], maxMs) : maxMs
            }
            return maxMs
        }
    }

    private struct Key: Hashable {
        let operation: AXCallOperation
        let name: String
    }

    private struct OperationStats {
        var histogram = Histogram()
        var outcomes: [String: Int] = [:]
    }

    private struct ThreadStats {
        var count = 0
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0
    }

    private struct ScopeStats {
        var histogram = Histogram()
        var failures = 0
    }

    private let wallMs: () -> Int64
    private let lock = NSLock()
    private var sinceMs: Int64
    private var calls = 0
    private var totalNanos: UInt64 = 0
    private var timeouts = 0
    private var slowCalls = 0
    private var operations: [Key: OperationStats] = [:]
    private var threads: [String: ThreadStats] = [:]
    private var scopes: [String: ScopeStats] = [:]
    private var slowSamples: [AXCallSample] = []

    public init(slowThresholdMs: Double = 500, keepSlowSamples: Int = 64,
                wallMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.slowThresholdMs = slowThresholdMs
        self.keepSlowSamples = keepSlowSamples
        self.wallMs = wallMs
        sinceMs = wallMs()
    }

    public func record(_ sample: AXCallSample) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        totalNanos &+= sample.nanos
        if sample.outcome == "cannotComplete" { timeouts += 1 }
        let key = Key(operation: sample.operation, name: sample.name)
        var stats = operations[key] ?? OperationStats()
        stats.histogram.add(sample.nanos)
        stats.outcomes[sample.outcome, default: 0] += 1
        for (label, n) in sample.itemOutcomes { stats.outcomes[label, default: 0] += n }
        operations[key] = stats
        var thread = threads[sample.thread] ?? ThreadStats()
        thread.count += 1
        thread.totalNanos &+= sample.nanos
        thread.maxNanos = max(thread.maxNanos, sample.nanos)
        threads[sample.thread] = thread
        if Double(sample.nanos) / 1_000_000 >= slowThresholdMs {
            slowCalls += 1
            slowSamples.append(sample)
            if slowSamples.count > keepSlowSamples { slowSamples.removeFirst(slowSamples.count - keepSlowSamples) }
        }
    }

    /// Times a span around many AX calls; kept apart from the per-call totals.
    public func recordScope(_ name: String, nanos: UInt64, ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var stats = scopes[name] ?? ScopeStats()
        stats.histogram.add(nanos)
        if !ok { stats.failures += 1 }
        scopes[name] = stats
    }

    public func report(topOperations: Int = 30) -> AXCallTimingReport {
        lock.lock()
        defer { lock.unlock() }
        let ops = operations
            .sorted { lhs, rhs in
                if lhs.value.histogram.totalNanos != rhs.value.histogram.totalNanos {
                    return lhs.value.histogram.totalNanos > rhs.value.histogram.totalNanos
                }
                return (lhs.key.operation.rawValue, lhs.key.name) < (rhs.key.operation.rawValue, rhs.key.name)
            }
            .prefix(max(0, topOperations))
            .map { key, stats in
                AXCallTimingReport.Operation(
                    operation: key.operation.rawValue, name: key.name, count: stats.histogram.count,
                    totalMs: Self.milliseconds(stats.histogram.totalNanos), maxMs: Self.milliseconds(stats.histogram.maxNanos),
                    p50Ms: stats.histogram.percentileMs(0.50), p95Ms: stats.histogram.percentileMs(0.95),
                    p99Ms: stats.histogram.percentileMs(0.99), outcomes: stats.outcomes
                )
            }
        let threadRows = threads
            .sorted { $0.value.totalNanos != $1.value.totalNanos ? $0.value.totalNanos > $1.value.totalNanos : $0.key < $1.key }
            .map { AXCallTimingReport.Thread(thread: $0.key, count: $0.value.count,
                                             totalMs: Self.milliseconds($0.value.totalNanos), maxMs: Self.milliseconds($0.value.maxNanos)) }
        let scopeRows = scopes
            .sorted { $0.key < $1.key }
            .map { name, stats in
                AXCallTimingReport.Scope(
                    name: name, count: stats.histogram.count, failures: stats.failures,
                    totalMs: Self.milliseconds(stats.histogram.totalNanos), maxMs: Self.milliseconds(stats.histogram.maxNanos),
                    p50Ms: stats.histogram.percentileMs(0.50), p95Ms: stats.histogram.percentileMs(0.95),
                    p99Ms: stats.histogram.percentileMs(0.99)
                )
            }
        return AXCallTimingReport(
            sinceMs: sinceMs, generatedMs: wallMs(), calls: calls, totalMs: Self.milliseconds(totalNanos),
            timeouts: timeouts, slowCalls: slowCalls, slowThresholdMs: slowThresholdMs,
            operations: Array(ops), threads: threadRows, scopes: scopeRows, slowSamples: slowSamples
        )
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        sinceMs = wallMs()
        calls = 0
        totalNanos = 0
        timeouts = 0
        slowCalls = 0
        operations = [:]
        threads = [:]
        scopes = [:]
        slowSamples = []
    }

    /// Fixed, content-free label for a failed call.
    public static func outcomeLabel(for error: Error) -> String {
        guard let error = error as? AXKitError else { return "error" }
        switch error {
        case .notTrusted: return "notTrusted"
        case .applicationNotRunning: return "applicationNotRunning"
        case .invalidElement: return "invalidElement"
        case .attributeUnsupported: return "unsupported"
        case .attributeNotSettable: return "notSettable"
        case .actionUnsupported: return "actionUnsupported"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        case .valueNotConvertible: return "valueNotConvertible"
        case .apiFailure(let code, _): return "error:\(code)"
        }
    }

    static func milliseconds(_ nanos: UInt64) -> Double {
        (Double(nanos) / 100_000).rounded() / 10
    }
}
