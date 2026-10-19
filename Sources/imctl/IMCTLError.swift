enum IMCTLError: Error, CustomStringConvertible {
    case notTrusted
    case noWindow(String)

    var description: String {
        switch self {
        case .notTrusted:
            return "this process is not trusted for Accessibility; run `imctl permission --prompt` and approve it in System Settings"
        case .noWindow(let attr):
            return "the application has no \(attr); is the client window open?"
        }
    }
}
