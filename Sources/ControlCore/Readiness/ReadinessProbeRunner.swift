import Foundation

/// Runs one round of live tests concurrently (B52). A probe still running at the deadline is reported as
/// `timeout`; its late result is dropped, so a stuck network call never holds the round or the next one.
public enum ReadinessProbeRunner {
    public static let deadlineSeconds: TimeInterval = 40

    public static func run(_ probes: [ReadinessProbeKind: () -> ReadinessProbeResult],
                           deadline: TimeInterval = deadlineSeconds) -> [ReadinessProbeKind: ReadinessProbeResult] {
        guard !probes.isEmpty else { return [:] }
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var results: [ReadinessProbeKind: ReadinessProbeResult] = [:]
        }
        let collected = Collected()
        let group = DispatchGroup()
        for (kind, probe) in probes {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = probe()
                collected.lock.lock(); collected.results[kind] = result; collected.lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + deadline)
        collected.lock.lock()
        var out = collected.results
        collected.lock.unlock()
        for kind in probes.keys where out[kind] == nil {
            out[kind] = .failure("timeout", latencyMs: Int((deadline * 1000).rounded()))
        }
        return out
    }
}
