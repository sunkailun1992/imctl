public enum AXKitError: Error, Equatable, CustomStringConvertible {
    case notTrusted
    case applicationNotRunning(bundleID: String)
    case invalidElement
    case attributeUnsupported(String)
    case attributeNotSettable(String)
    case actionUnsupported(String)
    case cannotComplete(String)
    case notImplemented(String)
    case valueNotConvertible(String)
    case apiFailure(code: Int32, operation: String)

    public var description: String {
        switch self {
        case .notTrusted: return "process is not trusted for Accessibility"
        case .applicationNotRunning(let b): return "application \(b) is not running"
        case .invalidElement: return "invalid or stale AX element"
        case .attributeUnsupported(let a): return "attribute \(a) unsupported"
        case .attributeNotSettable(let a): return "attribute \(a) not settable"
        case .actionUnsupported(let a): return "action \(a) unsupported"
        case .cannotComplete(let op): return "cannot complete \(op) (target not responding)"
        case .notImplemented(let op): return "not implemented by target: \(op)"
        case .valueNotConvertible(let d): return "value not convertible: \(d)"
        case .apiFailure(let code, let op): return "AX API failure \(code) during \(op)"
        }
    }
}
