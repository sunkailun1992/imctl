import Foundation

/// Accessibility is the TCC permission imctl asks for itself; B11 adds the deep links for the two the
/// user grants in System Settings (Full Disk Access covers the client's container after updates).
public enum AXPermission {
    /// Deep link to System Settings › Privacy & Security › Full Disk Access.
    public static var fullDiskAccessSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    public static func isTrusted(prompt: Bool = false, backend: AXBackend) -> Bool {
        backend.isProcessTrusted(prompt: prompt)
    }

    /// Deep link to System Settings › Privacy & Security › Accessibility.
    public static var accessibilitySettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
}
