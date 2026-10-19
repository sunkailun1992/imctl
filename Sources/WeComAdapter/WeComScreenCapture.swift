import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One in-memory frame containing only the verified WeCom window. `windowFrame`
/// describes the image in the same global point coordinates as AX row frames.
/// A display-backed window filter can return a transparent display-sized image.
public struct WeComWindowScreenshot {
    public let image: CGImage
    public let windowFrame: CGRect

    public init(image: CGImage, windowFrame: CGRect) {
        self.image = image
        self.windowFrame = windowFrame
    }
}

/// Captures a single WeCom window only when the caller already has Screen
/// Recording permission. This never requests permission, stores pixels, or
/// captures the desktop. B15 uses this locally for otherwise unresolvable
/// media direction; B17 may send the cropped, verified window to the selected
/// provider only during an explicitly authorized fixed desktop command.
public enum WeComScreenCapture {
    /// `windowID` names the one window a command proved it owns when another
    /// window of the client shares its frame (B49: the 添加客户 panel over the
    /// main window); nil keeps the geometric match, which refuses such a pair.
    public static func capture(
        windowPID: pid_t,
        expectedFrame: CGRect,
        timeout: TimeInterval = 2.0,
        includeChildWindows: Bool = false,
        windowID: CGWindowID? = nil
    ) -> WeComWindowScreenshot? {
        guard CGPreflightScreenCaptureAccess(),
              windowPID > 0,
              expectedFrame.width > 0,
              expectedFrame.height > 0,
              timeout.isFinite,
              timeout > 0 else { return nil }

        // ScreenCaptureKit filters call SkyLight display APIs. A launchd CLI
        // daemon has not initialized Core Graphics like an NSApplication has;
        // without this public display query filter creation can abort at
        // CGS_REQUIRE_INIT.
        _ = CGMainDisplayID()

        let deadline = ProcessInfo.processInfo.systemUptime + min(timeout, 10)
        let windows = CompletionBox<SCShareableContent>()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            windows.complete(content)
        }
        guard let content = windows.wait(until: deadline),
              let window = bestWindow(in: content.windows, pid: windowPID, expectedFrame: expectedFrame,
                                      windowID: windowID)
        else { return nil }

        // A display-backed filter includes only this verified window and no
        // desktop or other application windows. The desktop-independent filter
        // failed to start with SCStreamErrorInternalError on macOS 27.0.
        let displays = content.displays.filter { display in
            let overlap = display.frame.intersection(window.frame)
            return !overlap.isNull
                && overlap.width * overlap.height / (window.frame.width * window.frame.height) >= 0.97
        }
        guard displays.count == 1 else { return nil }
        let display = displays[0]
        let filter = SCContentFilter(display: display, including: [window])
        filter.includeMenuBar = false
        let image = CompletionBox<CGImage>()
        if #available(macOS 26.0, *) {
            // The screenshot-specific configuration returns a CGImage directly.
            // A nil fileURL guarantees no screenshot is written to disk.
            let configuration = SCScreenshotConfiguration()
            configuration.width = max(1, display.width)
            configuration.height = max(1, display.height)
            configuration.showsCursor = false
            configuration.ignoreShadows = true
            // The default excludes unrelated child panels. A command that
            // has independently proved ownership of an AX sheet may opt in
            // so the model sees that sheet instead of the obscured parent.
            configuration.includeChildWindows = includeChildWindows
            configuration.dynamicRange = .sdr
            configuration.fileURL = nil
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { output, _ in
                image.complete(output?.sdrImage)
            }
        } else {
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, display.width)
            configuration.height = max(1, display.height)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsDisplay = true
            configuration.includeChildWindows = includeChildWindows
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { capturedImage, _ in
                image.complete(capturedImage)
            }
        }
        guard let capturedImage = image.wait(until: deadline) else { return nil }
        return WeComWindowScreenshot(image: capturedImage, windowFrame: display.frame)
    }

    private static func bestWindow(in windows: [SCWindow], pid: pid_t, expectedFrame: CGRect,
                                   windowID: CGWindowID?) -> SCWindow? {
        let candidates = windows.map {
            WindowCandidate(id: $0.windowID, pid: $0.owningApplication?.processID, layer: $0.windowLayer, frame: $0.frame)
        }
        guard let chosen = chooseWindow(candidates, pid: pid, expectedFrame: expectedFrame, windowID: windowID) else { return nil }
        return windows.first { $0.windowID == chosen }
    }

    /// What the choice needs of a ScreenCaptureKit window, so it can be tested without one.
    struct WindowCandidate: Equatable {
        let id: CGWindowID
        let pid: pid_t?
        let layer: Int
        let frame: CGRect
    }

    /// A layer-0 window of `pid` covering nearly the same area as `expectedFrame`
    /// (each at least 97% of the other). Without `windowID` there must be exactly
    /// one: two nearly stacked windows from the same app — a second chat window,
    /// or the 添加客户 panel over the main window — cannot be matched to the AX
    /// element by geometry alone, and the screenshot is refused rather than taken
    /// of the wrong one. With `windowID`, only that window is taken, and only if
    /// it passes the same checks.
    static func chooseWindow(_ candidates: [WindowCandidate], pid: pid_t, expectedFrame: CGRect,
                             windowID: CGWindowID?) -> CGWindowID? {
        let matches = candidates.filter {
            $0.pid == pid && $0.layer == 0 && WeComWindowIdentity.sameArea($0.frame, expectedFrame)
        }
        if let windowID { return matches.contains { $0.id == windowID } ? windowID : nil }
        return matches.count == 1 ? matches[0].id : nil
    }
}

/// The ScreenCaptureKit completion handlers have no synchronous variant. A
/// deadline bounds both asynchronous stages for the existing synchronous read
/// path; a late callback releases its image without affecting the caller.
private final class CompletionBox<Value> {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Value?

    func complete(_ value: Value?) {
        lock.lock()
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(until deadline: TimeInterval) -> Value? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        if Thread.isMainThread {
            // The watcher polls on the daemon's main run loop. Pump it in
            // short slices so a ScreenCaptureKit callback delivered on the
            // main queue can complete instead of timing out behind our wait.
            var signalled = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if semaphore.wait(timeout: .now()) == .success { signalled = true; break }
                let slice = min(0.01, deadline - ProcessInfo.processInfo.systemUptime)
                if slice > 0 { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: slice)) }
            }
            guard signalled || semaphore.wait(timeout: .now()) == .success else { return nil }
        } else {
            guard semaphore.wait(timeout: .now() + remaining) == .success else { return nil }
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
