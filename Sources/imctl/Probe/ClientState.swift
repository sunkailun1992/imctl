import AppKit
import AXKit

/// Whether the IM client is in front, sampled around an action so the gate
/// note can prove the action did not activate it.
struct ClientState: Codable, Equatable {
    var clientActive: Bool?
    var clientHidden: Bool?
    var frontmostBundle: String?

    static func sample(bundleID: String, fixture: Bool) -> ClientState {
        if fixture { return ClientState(clientActive: nil, clientHidden: nil, frontmostBundle: "fixture") }
        let app = AXApp.runningApplication(bundleID: bundleID)
        return ClientState(
            clientActive: app?.isActive,
            clientHidden: app?.isHidden,
            frontmostBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    var summary: String {
        "client_active=\(clientActive.map(String.init) ?? "n/a") hidden=\(clientHidden.map(String.init) ?? "n/a") frontmost=\(frontmostBundle ?? "-")"
    }
}
