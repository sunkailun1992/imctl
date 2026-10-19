import AXKit
import CoreGraphics

/// A command may include a child sheet or popover in its parent-window frame
/// only after AX proves that exactly one overlay belongs to its current step.
/// The caller still rechecks its method-specific title, contents and target;
/// this guard prevents an unrelated sibling overlay from entering the image.
enum CommandOwnedChildCapture {
    typealias Overlay = (role: String, handle: AXElementHandle, candidate: AXElementHandle)

    /// `windowID` is a window number the command proved it owns (a panel it
    /// opened, or the window it opened it from) for when two client windows
    /// share one frame; nil leaves the choice to geometry.
    static func capture(window: AXElement, pid: pid_t, frame: CGRect,
                        ownedOverlay: Overlay? = nil, windowID: CGWindowID? = nil,
                        captureFrame: (pid_t, CGRect, Bool, CGWindowID?) -> WeComWindowScreenshot? = {
                            WeComScreenCapture.capture(windowPID: $0, expectedFrame: $1,
                                                       includeChildWindows: $2, windowID: $3)
                        }) -> WeComWindowScreenshot? {
        if let ownedOverlay,
           !containsOnlyOwnedOverlay(in: window, role: ownedOverlay.role,
                                     overlayHandle: ownedOverlay.handle,
                                     candidateHandle: ownedOverlay.candidate) {
            return nil
        }
        return captureFrame(pid, frame, ownedOverlay != nil, windowID)
    }

    static func containsOnlyOwnedOverlay(in window: AXElement, role: String,
                                         overlayHandle: AXElementHandle,
                                         candidateHandle: AXElementHandle) -> Bool {
        let overlays = window.descendants(maxDepth: 14, maxNodes: 6000).filter {
            guard let observedRole = try? $0.role() else { return false }
            return [AXRole.sheet, AXRole.popover, "AXDialog"].contains(observedRole)
        }
        guard overlays.count == 1, overlays[0].handle == overlayHandle,
              (try? overlays[0].role()) == role else { return false }
        return overlays[0].descendants(maxDepth: 8, maxNodes: 2000)
            .contains { $0.handle == candidateHandle }
    }
}
