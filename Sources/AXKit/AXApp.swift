import AppKit
import Foundation

public enum AXApp {
    public static func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// LaunchServices can briefly report a running app as absent: live 2026-09-28 15:54 and
    /// 2026-09-29 00:28 a command failed with "not running" while WeCom had run since 09-24.
    /// The workspace list is a second look at no cost. Off the main thread (commands) two more
    /// looks follow 0.1 s apart; the watcher's main-thread poll never sleeps and simply looks
    /// again on its next tick.
    public static func byBundleID(_ bundleID: String, backend: AXBackend) throws -> AXElement {
        // The workspace list refreshes on the main run loop only, so off it a terminated
        // instance can linger with its old pid: take live instances only.
        func lookup() -> NSRunningApplication? {
            let live = { (app: NSRunningApplication) in !app.isTerminated && app.processIdentifier > 0 }
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: live)
                ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && live($0) }
        }
        if let app = lookup() { return byPID(app.processIdentifier, backend: backend) }
        if !Thread.isMainThread {
            for _ in 0..<2 {
                Thread.sleep(forTimeInterval: 0.1)
                if let app = lookup() { return byPID(app.processIdentifier, backend: backend) }
            }
        }
        throw AXKitError.applicationNotRunning(bundleID: bundleID)
    }

    public static func byPID(_ pid: pid_t, backend: AXBackend) -> AXElement {
        AXElement(handle: backend.applicationElement(pid: pid), backend: backend)
    }
}
