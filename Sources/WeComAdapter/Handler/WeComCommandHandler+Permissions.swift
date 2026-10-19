import AXKit
import ControlCore
import CoreGraphics
import Foundation

private enum ScreenRecordingPrompt {
    static let lock = NSLock()
    static var inFlight = false

    static func requestOnce() {
        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        Thread {
            _ = CGRequestScreenCaptureAccess()
            lock.lock()
            inFlight = false
            lock.unlock()
        }.start()
    }
}

/// What this daemon may do on this Mac, judged from inside the daemon (grants are per process).
/// `prompt` triggers Accessibility, Screen Recording, and the client's container dialogs. Full Disk
/// Access cannot be prompted, only opened in System Settings.
extension WeComCommandHandler {
    public static var permissionsProbeTimeout: TimeInterval = 4

    /// Read-only TCC check used at each explicit visual staging boundary.
    /// A granted capture at the previous model round does not prove that the
    /// permission is still present before a later AX write or Return.
    static func screenRecordingGrantedNow() -> Bool { CGPreflightScreenCaptureAccess() }

    public func permissions(prompt: Bool, probe: Bool) throws -> [String: String] {
        var out: [String: String] = [:]
        let trusted = (try? rootProvider().backend.isProcessTrusted(prompt: prompt)) ?? LiveAXBackend().isProcessTrusted(prompt: prompt)
        out["accessibility"] = trusted ? "trusted" : "untrusted"
        let screenGranted = CGPreflightScreenCaptureAccess()
        out["screenRecording"] = screenGranted ? "granted" : "denied"
        if prompt && !screenGranted {
            // The system dialog may wait for a person. Keep the socket command responsive while macOS
            // attributes this request to the daemon's stable signed identity.
            ScreenRecordingPrompt.requestOnce()
        }
        out["fullDiskAccess"] = Self.hasFullDiskAccess() ? "yes" : "no"
        out["clientRunning"] = (try? rootProvider()) != nil ? "true" : "false"
        out["launchAgent"] = ProcessInfo.processInfo.environment["IMCTL_LAUNCHD"] == "1" ? "true" : "false"
        let container = mediaStore.containerData
        out["wecomDataPath"] = container.path
        if prompt || probe || out["fullDiskAccess"] == "yes" {
            out["wecomData"] = Self.probeContainer(container, timeout: Self.permissionsProbeTimeout)
        } else {
            out["wecomData"] = "unknown (pass prompt:true to probe; probing shows the system dialog once)"
        }
        out["prompted"] = prompt ? "true" : "false"
        return out
    }

    /// A TCC database opens only for a Full Disk Access holder. macOS ≤ 26 has one under
    /// `~/Library/Application Support/com.apple.TCC/`; macOS 27.0 (2026-09-22) dropped that per-user file,
    /// so the system one under `/Library/Application Support/com.apple.TCC/` is tried as well.
    static func hasFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser, systemRoot: URL = URL(fileURLWithPath: "/")) -> Bool {
        [home, systemRoot].contains { root in
            let tcc = root.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
            guard let h = FileHandle(forReadingAtPath: tcc.path) else { return false }
            defer { try? h.close() }
            return (try? h.read(upToCount: 4)) != nil
        }
    }

    /// granted | denied | pending (the dialog is up) | absent.
    static func probeContainer(_ url: URL, timeout: TimeInterval) -> String {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return "absent" }
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box(); let done = DispatchSemaphore(value: 0)
        Thread {
            do { _ = try FileManager.default.contentsOfDirectory(atPath: url.path); box.value = "granted" }
            catch { box.value = (error as NSError).code == NSFileReadNoPermissionError || (error as NSError).code == 257 ? "denied" : "error: \((error as NSError).localizedDescription)" }
            done.signal()
        }.start()
        return done.wait(timeout: .now() + timeout) == .success ? (box.value ?? "unknown") : "pending"
    }
}
