import AXKit

/// Finds the WeCom main window. When the window lives on another Space it is
/// absent from `AXChildren` and `AXWindows` but still reachable through
/// `AXMainWindow` (verified 2026-09-11 on 5.0.10).
public enum WeComWindowLocator {
    public static func mainWindow(from root: AXElement) throws -> AXElement {
        let role = try root.role()
        if role == AXRole.window { return root }
        guard role == AXRole.application else { throw WeComError.noWindow }
        if let w = try root.element(AXAttribute.mainWindow) { return w }
        if let w = try root.element(AXAttribute.focusedWindow) { return w }
        if let w = try root.elements(AXAttribute.windows).first { return w }
        throw WeComError.noWindow
    }
}
