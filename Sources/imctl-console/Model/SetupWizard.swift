import ControlCore
import Foundation

/// B53 first-run wizard: the steps, what counts as done (read from a local readiness report), and the stored flag.
struct SetupWizard: Equatable {
    enum Feature: String, CaseIterable, Hashable {
        case agents, mqtt, vision, oss, proxy
        var title: String {
            switch self {
            case .agents: "Claude Code / Codex 接入"
            case .mqtt: "MQTT（Java / 远端调用）"
            case .vision: "视觉兜底"
            case .oss: "OSS 文件"
            case .proxy: "企微官方 API 代理"
            }
        }
        var capabilityID: String {
            switch self {
            case .agents: "agents"
            case .mqtt: "mqtt"
            case .vision: "vision"
            case .oss: "oss"
            case .proxy: "wecomApi"
            }
        }
        /// Saved settings take effect only after the daemon restarts (a reinstall also switches MQTT mode on).
        var needsRestartAfterSave: Bool { self != .agents }
    }

    enum Step: Equatable, Hashable {
        case install, wecom, sendScope, features, configure(Feature), apply, finish
        var title: String {
            switch self {
            case .install: "安装与授权"
            case .wecom: "企业微信"
            case .sendScope: "发送范围"
            case .features: "要用哪些功能"
            case .configure(let f): f.title
            case .apply: "应用配置"
            case .finish: "完成"
            }
        }
        var required: Bool { self == .install || self == .wecom }
    }

    static let flagKey = "imctl.setupWizard.done"
    static func flagDone(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: flagKey) }
    static func markDone(_ defaults: UserDefaults) { defaults.set(true, forKey: flagKey) }
    /// The wizard opens by itself only on a launch that is not ready before it was ever finished or closed.
    static func shouldAutoOpen(report: ReadinessReport?, flagDone: Bool) -> Bool { !flagDone && report?.ready != true }

    var selected: Set<Feature> = []
    var needsApply = false
    var index = 0
    var skipped: [Step] = []

    var steps: [Step] {
        var s: [Step] = [.install, .wecom, .sendScope, .features]
        s += Feature.allCases.filter { selected.contains($0) }.map { .configure($0) }
        if needsApply { s.append(.apply) }
        s.append(.finish)
        return s
    }
    var current: Step { steps[min(index, steps.count - 1)] }

    mutating func next() { index = min(index + 1, steps.count - 1) }
    mutating func back() { index = max(index - 1, 0) }
    mutating func skip() {
        if current.required, !skipped.contains(current) { skipped.append(current) }
        next()
    }
    mutating func featureSaved(_ feature: Feature) { if feature.needsRestartAfterSave { needsApply = true } }
    mutating func applied() { needsApply = false }

    static func preselected(_ report: ReadinessReport?) -> Set<Feature> {
        guard let report else { return [] }
        return Set(Feature.allCases.filter { f in report.capabilities.first { $0.id == f.capabilityID }.map { $0.status != .disabled } ?? false })
    }

    static func isDone(_ step: Step, report: ReadinessReport?) -> Bool {
        if step == .sendScope || step == .features { return true }
        guard let report else { return false }
        func capability(_ id: String) -> ReadinessCapability? { report.capabilities.first { $0.id == id } }
        switch step {
        case .install:
            return ["daemon", "read", "media"].allSatisfy { capability($0).map { $0.status != .fail } ?? false }
        case .wecom:
            return capability("wecom")?.status == .ok
        case .configure(let feature):
            guard let c = capability(feature.capabilityID) else { return false }
            if feature == .agents { return c.status == .ok }
            return c.status != .disabled && !c.checks.contains { $0.id == "config" && $0.status == .fail }
        case .sendScope, .features, .apply, .finish:
            return false
        }
    }
}
