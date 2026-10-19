import AppKit
import AXKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Live host probes. Each probe returns nil on any failure and never prompts.
enum HostProbe {
    static func snapshot(bundleID: String, backend: AXBackend) -> HostEnvironment {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let signing = CodeSigningInfo.current()
        return HostEnvironment(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture,
            accessibilityTrusted: backend.isProcessTrusted(prompt: false),
            clamshellClosed: clamshellClosed(),
            sleepDisabled: sleepDisabled(),
            onACPower: onACPower(),
            screenLocked: screenLocked(),
            displayAsleep: displayAsleep(),
            displayCount: NSScreen.screens.count,
            client: client(bundleID: bundleID),
            process: .init(
                executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "?",
                signingIdentifier: signing.identifier,
                signingTeam: signing.team,
                signed: signing.signed
            )
        )
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// `AppleClamshellState` on IOPMrootDomain: true when the lid is closed.
    static func clamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return boolValue(raw.takeRetainedValue())
    }

    /// `SleepDisabled` as written by `pmset -a disablesleep 1`. The IOKit
    /// getter is not exposed to Swift, so read the world-readable preference
    /// file pmset maintains.
    static func sleepDisabled() -> Bool? {
        let path = "/Library/Preferences/com.apple.PowerManagement.plist"
        guard let plist = NSDictionary(contentsOfFile: path),
              let settings = plist["SystemPowerSettings"] as? [String: Any],
              let raw = settings["SleepDisabled"] else { return nil }
        return boolValue(raw as AnyObject)
    }

    static func onACPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return (type as String) == kIOPMACPowerKey
    }

    /// `CGSSessionScreenIsLocked` is present in the session dictionary only while locked.
    static func screenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        guard let raw = session["CGSSessionScreenIsLocked"] else { return false }
        return boolValue(raw as AnyObject)
    }

    static func displayAsleep() -> Bool? {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    static func client(bundleID: String) -> HostEnvironment.ClientInfo? {
        guard let app = AXApp.runningApplication(bundleID: bundleID) else { return nil }
        let version = app.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary?["CFBundleShortVersionString"] as? String
        return .init(bundleID: bundleID, version: version, pid: app.processIdentifier, hidden: app.isHidden, active: app.isActive)
    }

    private static func boolValue(_ raw: AnyObject) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }
}
