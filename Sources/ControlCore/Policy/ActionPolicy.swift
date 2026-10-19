public enum PolicyError: Error, Equatable, CustomStringConvertible {
    case notEnabled(ActionKind)
    case targetNotAllowed(String)
    case phaseForbids(ActionKind)
    case targetRequired(ActionKind)

    public var description: String {
        switch self {
        case .notEnabled(let k): return "action \(k.rawValue) not enabled (pass the matching --allow-* flag)"
        case .targetNotAllowed(let t): return "target \"\(t)\" is not allowed by the compiled-in allowlist or policy.json"
        case .phaseForbids(let k): return "action \(k.rawValue) is forbidden in the current phase"
        case .targetRequired(let k): return "action \(k.rawValue) needs a target conversation"
        }
    }
}

/// "Code decides what may move." The allowlist is compiled in by the caller,
/// the policy file (`SendPolicy`) can only add to it, enabling is per
/// invocation, and the phase caps what any flag can unlock.
public struct ActionPolicy {
    public enum Phase { case phase0, phase1 }

    /// Compiled in by the caller; the policy file can only add to it.
    public var allowedTargets: Set<String>
    public var enabled: Set<ActionKind>
    public var phase: Phase
    public var sendPolicy: SendPolicy

    public init(allowedTargets: Set<String>, enabled: Set<ActionKind> = [], phase: Phase = .phase0, sendPolicy: SendPolicy = SendPolicy()) {
        self.allowedTargets = allowedTargets
        self.enabled = enabled
        self.phase = phase
        self.sendPolicy = sendPolicy
    }

    /// Titles allowed by code or by the policy file.
    public var effectiveTitles: Set<String> { allowedTargets.union(sendPolicy.allowedTitles) }

    /// `allowAll` first (user decision 2026-09-22, 「全部放开」): `allowAll` is the only exception to
    /// the TYPE rule（类型规则永远不放行 `unknown`；`allowAll` 是用户明确开启、只本机、有日志的唯一
    /// 例外） — local-only switch, never settable through `policy.set`. Then title rule, id rules,
    /// and the type rule itself: the title / chatId / externalUserId rules never check the target's
    /// type at all, so an allowlisted title resolves as `unknown` and passes just as easily.
    public func allows(_ target: ResolvedTarget) -> Bool {
        if sendPolicy.allowAll { return true }
        if effectiveTitles.contains(target.title) { return true }
        if let id = target.chatId, sendPolicy.allowedChatIds.contains(id) { return true }
        if let id = target.externalUserId, sendPolicy.allowedExternalUserIds.contains(id) { return true }
        return sendPolicy.allowedTypes.allows(target.type)
    }

    /// Order: phase → enabled → target present → target allowed. A bare title
    /// is judged with an unknown kind and no ids.
    public func authorize(_ kind: ActionKind, target: String?) throws {
        try authorize(kind, resolved: target.map { ResolvedTarget(title: $0) })
    }

    public func authorize(_ kind: ActionKind, resolved target: ResolvedTarget?) throws {
        if phase == .phase0, kind == .submit || kind == .sendFile || kind == .addGroupMembers { throw PolicyError.phaseForbids(kind) }
        guard enabled.contains(kind) else { throw PolicyError.notEnabled(kind) }
        guard kind.requiresTarget else { return }
        guard let target, !target.title.isEmpty else { throw PolicyError.targetRequired(kind) }
        if kind.isReadOnly, !sendPolicy.gateReads { return }   // B10: opening / scrolling a conversation is not gated by default
        guard allows(target) else { throw PolicyError.targetNotAllowed(target.title) }
    }
}
