import Foundation

/// Process-local, content-free counters for explicit B17 visual command rounds.
/// Values are cumulative since daemon start; no image, AX label, prompt, model
/// response, target, or credential is retained here.
public enum AIPlannerDiagnostics {
    public struct Snapshot: Equatable, Sendable {
        public let captureCount: UInt64
        public let requestCount: UInt64
        /// HTTP 200 responses from the selected provider, before JSON validation.
        public let successCount: UInt64
    }

    private static let counters = Counters()

    public static func snapshot() -> Snapshot { counters.snapshot() }

    static func recordCapture() { counters.recordCapture() }
    static func recordRequest() { counters.recordRequest() }
    static func recordSuccess() { counters.recordSuccess() }

    /// A separate instance lets tests check counting and concurrency without
    /// resetting the daemon's cumulative counters.
    final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var captures: UInt64 = 0
        private var requests: UInt64 = 0
        private var successes: UInt64 = 0

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(captureCount: captures, requestCount: requests,
                            successCount: successes)
        }

        func recordCapture() {
            lock.lock()
            defer { lock.unlock() }
            if captures < UInt64.max { captures += 1 }
        }

        func recordRequest() {
            lock.lock()
            defer { lock.unlock() }
            if requests < UInt64.max { requests += 1 }
        }

        func recordSuccess() {
            lock.lock()
            defer { lock.unlock() }
            if successes < UInt64.max { successes += 1 }
        }
    }
}
