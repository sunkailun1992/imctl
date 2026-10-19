import Foundation

/// When `controller.readiness` may start a round of live tests (B52). Pure: the caller holds a lock and
/// passes the clock. One round at a time; a finished round serves every caller for `cacheMs`; `refresh`
/// starts a new one only `refreshFloorMs` after the last start, whoever asks (socket, MQTT or MCP).
/// A round is only reused for the configuration it tested: another `fingerprint` starts a new one at once.
public struct ReadinessOnlineState: Equatable, Sendable {
    public static let cacheMs: Int64 = 300_000
    public static let refreshFloorMs: Int64 = 60_000

    public enum Decision: Equatable, Sendable { case skip, serve, start }

    public private(set) var running = false
    public private(set) var lastStartMs: Int64?
    public private(set) var results: [ReadinessProbeKind: ReadinessProbeResult]?
    public private(set) var testedMs: Int64?
    /// The configuration the running (or last started) round tests.
    public private(set) var roundFingerprint: String?
    /// The configuration `results` were tested against.
    public private(set) var resultsFingerprint: String?

    public init() {}

    public mutating func request(online: Bool, refresh: Bool, nowMs: Int64, fingerprint: String = "") -> Decision {
        guard online else { return .skip }
        if running { return .serve }
        if fingerprint == resultsFingerprint {
            if refresh, let lastStartMs, nowMs - lastStartMs < Self.refreshFloorMs { return .serve }
            if !refresh, results != nil, let testedMs, nowMs - testedMs < Self.cacheMs { return .serve }
        }
        running = true
        lastStartMs = nowMs
        roundFingerprint = fingerprint
        return .start
    }

    public mutating func finish(_ results: [ReadinessProbeKind: ReadinessProbeResult], nowMs: Int64) {
        self.results = results
        testedMs = nowMs
        resultsFingerprint = roundFingerprint
        running = false
    }

    public func info(online: Bool, nowMs: Int64) -> ReadinessOnlineInfo {
        let next = lastStartMs.map { $0 + Self.refreshFloorMs }
        guard online else { return ReadinessOnlineInfo(state: "skipped", testedMs: testedMs, nextRefreshAllowedMs: next) }
        return ReadinessOnlineInfo(state: running ? "running" : "done", testedMs: testedMs, nextRefreshAllowedMs: next)
    }
}
