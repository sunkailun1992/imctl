import AXKit
import CoreGraphics
import Foundation

extension WeComCommandHandler {
    /// Read-only B55 compatibility for the macOS sharing indicator observed on
    /// 2026-10-19: a 66 x 20 AXDialog at the main window's (12, 4), containing
    /// one WindowSharingSessionButton whose frame extends one point per edge.
    /// Its exact shape is an allowlisted accessory, never a new action target.
    static func verifyGroupNameWindowSet(app: AXElement, window: AXElement, pid: pid_t,
                                         frame: CGRect, fieldFrame: CGRect,
                                         conversationTableFrame: CGRect, viewportFrame: CGRect,
                                         onRejection: ((GroupNameVisualGuard) -> Void)? = nil) throws {
        func finitePositive(_ rect: CGRect) -> Bool {
            rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0
        }
        func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            finitePositive(lhs) && finitePositive(rhs)
                && abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
                && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
        }

        guard pid > 0, app.backend === window.backend,
              try app.role() == AXRole.application, try app.pid() == pid,
              try window.role() == AXRole.window, try window.pid() == pid,
              finitePositive(frame), finitePositive(fieldFrame),
              finitePositive(conversationTableFrame), finitePositive(viewportFrame),
              let currentFrame = try window.frame(), sameFrame(currentFrame, frame) else {
            onRejection?(.identity)
            throw AIPlannerVisionError.staleView
        }
        let windows = try app.elements(AXAttribute.windows)
        guard (1...2).contains(windows.count),
              windows.filter({ $0.handle == window.handle }).count == 1,
              try app.element(AXAttribute.mainWindow)?.handle == window.handle else {
            onRejection?(.windowSetCount)
            throw AIPlannerVisionError.staleView
        }
        if let focused = try app.element(AXAttribute.focusedWindow), focused.handle != window.handle {
            onRejection?(.identity)
            throw AIPlannerVisionError.staleView
        }
        guard windows.count == 2 else { return }

        guard try window.subrole() == "AXStandardWindow",
              let indicator = windows.first(where: { $0.handle != window.handle }),
              indicator.backend === window.backend,
              try indicator.pid() == pid, try indicator.role() == AXRole.window,
              try indicator.subrole() == "AXDialog",
              let indicatorFrame = try indicator.frame(),
              sameFrame(indicatorFrame, CGRect(x: frame.minX + 12, y: frame.minY + 4, width: 66, height: 20)) else {
            onRejection?(.indicatorShape)
            throw AIPlannerVisionError.staleView
        }
        let children = try indicator.children()
        guard children.count == 1 else {
            onRejection?(.indicatorButton)
            throw AIPlannerVisionError.staleView
        }
        let button = children[0]
        guard button.backend === window.backend,
              try button.pid() == pid, try button.role() == AXRole.button,
              try button.subrole() == nil,
              try button.title() == "WindowSharingSessionButton",
              try button.children().isEmpty,
              let buttonFrame = try button.frame(),
              sameFrame(buttonFrame, indicatorFrame.insetBy(dx: -1, dy: -1)) else {
            onRejection?(.indicatorButton)
            throw AIPlannerVisionError.staleView
        }
        let accessory = indicatorFrame.union(buttonFrame)
        guard frame.contains(accessory),
              (accessory.maxX <= conversationTableFrame.minX || accessory.maxY <= conversationTableFrame.minY),
              !accessory.intersects(conversationTableFrame),
              !accessory.intersects(viewportFrame), !accessory.intersects(fieldFrame) else {
            onRejection?(.accessoryOverlap)
            throw AIPlannerVisionError.staleView
        }
    }
}
