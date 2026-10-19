public enum WeComError: Error, Equatable, CustomStringConvertible {
    case noWindow
    case region(String)

    public var description: String {
        switch self {
        case .noWindow: return "WeCom has no reachable main window (AXMainWindow/AXFocusedWindow/AXWindows all empty)"
        case .region(let name): return "could not locate WeCom region \(name) in the window"
        }
    }
}
