public enum ActionError: Error, Equatable, CustomStringConvertible {
    case targetNotFound(String)
    case targetAmbiguous(String, count: Int)
    case targetMismatch(expected: String, actual: String?)
    case localGuard(String)
    case verifyFailed(String)
    case notSettable(String)
    case actionUnavailable(String)
    /// B14: the target conversation shows no member list (no "(N)" in the header, no `群成员·N`
    /// side panel), so members cannot be added to it. Wire code `NOT_A_GROUP`.
    case notAGroup(String)

    public var description: String {
        switch self {
        case .targetNotFound(let t): return "TARGET_NOT_FOUND: no conversation titled \"\(t)\""
        case .targetAmbiguous(let t, let n): return "TARGET_AMBIGUOUS: \(n) conversations titled \"\(t)\""
        case .targetMismatch(let e, let a): return "TARGET_MISMATCH: expected \"\(e)\", active is \"\(a ?? "-")\""
        case .localGuard(let why): return "LOCAL_GUARD: \(why)"
        case .verifyFailed(let what): return "VERIFY_FAILED: \(what)"
        case .notSettable(let attr): return "attribute \(attr) is not settable on this client"
        case .actionUnavailable(let name): return "action \(name) is not available on this client"
        case .notAGroup(let t): return "NOT_A_GROUP: \"\(t)\" shows no member count: it is not a group"
        }
    }
}

public struct ActionOutcome: Equatable, Codable {
    public var kind: String
    public var target: String?
    public var verified: Bool
    public var details: [String: String]
}
