import Foundation

/// B52 `controller.readiness`: how ready this Mac is, capability by capability. A query like
/// `event.replay`: no command record, no events. Every string is a state, a count, a fixed category or
/// fixed advice — never a key, phone number, conversation title, broker host or bucket name.
public enum ReadinessStatus: String, Codable, Equatable, Sendable {
    case ok, fail, disabled, unknown
}

/// What to do about a capability. `command` starts with `imctl ` when it is this CLI; renderers swap in
/// the path the reader can run (`ReadinessCommandText`). `action` (B53) is what a fix button does.
public struct ReadinessFix: Codable, Equatable, Sendable {
    public var text: String
    public var command: String?
    public var action: ReadinessAction?
    public init(text: String, command: String? = nil, action: ReadinessAction? = nil) {
        self.text = text; self.command = command; self.action = action
    }
}

public struct ReadinessCheck: Codable, Equatable, Sendable {
    public var id: String
    public var status: ReadinessStatus
    public var detail: String
    /// Live checks only: true when this report carries a live result, false when it does not.
    public var tested: Bool?
    public var latencyMs: Int?
    public init(id: String, status: ReadinessStatus, detail: String, tested: Bool? = nil, latencyMs: Int? = nil) {
        self.id = id; self.status = status; self.detail = detail; self.tested = tested; self.latencyMs = latencyMs
    }
}

public struct ReadinessCapability: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var required: Bool
    public var status: ReadinessStatus
    public var checks: [ReadinessCheck]
    /// For `fail`: how to fix it. For `disabled`: how to enable it.
    public var fix: ReadinessFix?
    public var warnings: [String]
    public init(id: String, title: String, required: Bool, status: ReadinessStatus, checks: [ReadinessCheck],
                fix: ReadinessFix? = nil, warnings: [String] = []) {
        self.id = id; self.title = title; self.required = required; self.status = status
        self.checks = checks; self.fix = fix; self.warnings = warnings
    }
}

public struct ReadinessOnlineInfo: Codable, Equatable, Sendable {
    /// `skipped` (online:false) | `running` | `done`.
    public var state: String
    /// When the last finished round ended.
    public var testedMs: Int64?
    /// Earliest time a `refresh` starts a new round.
    public var nextRefreshAllowedMs: Int64?
    public init(state: String, testedMs: Int64? = nil, nextRefreshAllowedMs: Int64? = nil) {
        self.state = state; self.testedMs = testedMs; self.nextRefreshAllowedMs = nextRefreshAllowedMs
    }
}

public struct ReadinessReport: Codable, Equatable, Sendable {
    public var ready: Bool
    public var nextStep: ReadinessFix?
    public var nextStepCapability: String?
    public var capabilities: [ReadinessCapability]
    public var online: ReadinessOnlineInfo
    public var version: String
    public var generatedMs: Int64
    /// B53: the build the daemon is running (CFBundleVersion read at its start); nil outside an app bundle.
    public var build: String?
    /// B53: commands accepted or running when the report was made; clients refuse a daemon restart while > 0.
    public var runningCommands: Int?
    public init(ready: Bool, nextStep: ReadinessFix?, nextStepCapability: String?, capabilities: [ReadinessCapability],
                online: ReadinessOnlineInfo, version: String, generatedMs: Int64, build: String? = nil, runningCommands: Int? = nil) {
        self.ready = ready; self.nextStep = nextStep; self.nextStepCapability = nextStepCapability
        self.capabilities = capabilities; self.online = online; self.version = version; self.generatedMs = generatedMs
        self.build = build; self.runningCommands = runningCommands
    }
}

/// Which live test a result belongs to.
public enum ReadinessProbeKind: String, Codable, CaseIterable, Sendable {
    case vision, mqtt, oss, agents, wecomApi
}

/// One live test's outcome: a fixed category on failure, never remote text.
public struct ReadinessProbeResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var category: String?
    public var latencyMs: Int
    public init(ok: Bool, category: String?, latencyMs: Int) { self.ok = ok; self.category = category; self.latencyMs = latencyMs }
    public static func success(latencyMs: Int) -> ReadinessProbeResult { ReadinessProbeResult(ok: true, category: nil, latencyMs: latencyMs) }
    public static func failure(_ category: String, latencyMs: Int) -> ReadinessProbeResult {
        ReadinessProbeResult(ok: false, category: category, latencyMs: latencyMs)
    }
    /// Milliseconds since `start`, never negative.
    public static func elapsedMs(since start: Date, now: Date = Date()) -> Int { max(0, Int((now.timeIntervalSince(start) * 1000).rounded())) }
}

/// Answers `controller.readiness`. Must return quickly: no AX tree reads and no network on the caller's thread.
public protocol ReadinessProviding: AnyObject {
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport
}
