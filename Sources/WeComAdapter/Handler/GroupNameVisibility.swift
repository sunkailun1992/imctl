import AXKit
import ControlCore
import Foundation

extension WeComCommandHandler {
    /// A main window on another Space can remain AX-readable while AXWindows
    /// is an explicit empty array. Make it frontmost once, then require the
    /// original window and selected group to survive before B37/B55 run.
    /// Empty or unknown window collections never substitute for those guards.
    func withVisibleGroupNameWindow<T>(target: ResolvedTarget, actions: WeComActions,
                                       _ body: (AXElement) throws -> T) throws -> T {
        let root = try rootProvider()
        let window = try WeComWindowLocator.mainWindow(from: root)
        guard desktopCommandOrigin == .external, desktopCommandMethod == .groupRename,
              actions.visualObserveGroupName != nil else { return try body(window) }
        let app: AXElement
        if window.backend.name == "live" {
            app = AXApp.byPID(try window.pid(), backend: window.backend)
        } else {
            // Keep the legacy window-only fixture path; app-rooted fakes use
            // the same preparation and final window-set guard as production.
            guard try root.role() == AXRole.application else { return try body(window) }
            app = root
        }

        beginVisualStep(.control(.groupNameField), phase: .prepare)
        var restore: (() -> Void)?
        defer { restore?() }
        func windowHandles() throws -> [AXElementHandle] {
            guard case .elements(let handles)? = try app.attribute(AXAttribute.windows) else {
                throw AIPlannerVisionError.staleView
            }
            return handles
        }
        let initialHandles: [AXElementHandle]
        do {
            initialHandles = try windowHandles()
        } catch let error as AIPlannerVisionError {
            throw visualEnded("group title window preparation: \(error)", outcome: error.logName)
        }
        guard initialHandles.isEmpty else { return try body(window) }
        do {
            let pid = try window.pid()
            guard pid > 0, app.backend === window.backend,
                  try app.role() == AXRole.application, try app.pid() == pid,
                  try window.role() == AXRole.window, try window.subrole() == "AXStandardWindow",
                  try app.element(AXAttribute.mainWindow)?.handle == window.handle,
                  try app.element(AXAttribute.focusedWindow)?.handle == window.handle,
                  let frame = try window.frame(),
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
                throw AIPlannerVisionError.staleView
            }
            let original = try WeComReader(window: window)
            let selected = try original.conversations().filter(\.selected)
            guard selected.count == 1, selected[0].title == target.title,
                  try original.activeConversationHeader()?.title == target.title,
                  try AXElement(handle: selected[0].handle, backend: window.backend).pid() == pid,
                  let actionGate = actions.visualActionGate else { throw AIPlannerVisionError.staleView }
            let rowHandle = selected[0].handle
            let settings = try visualSettingsForCommit()

            func gate() throws {
                guard desktopCommandOrigin == .external, desktopCommandMethod == .groupRename,
                      visualEnabled(), visualSelect != nil,
                      app.backend.isProcessTrusted(prompt: false), visualScreenRecordingGranted(),
                      settings.fullWindowEnabled, settings.keyPresent,
                      try visualSettingsForCommit() == settings else { throw AIPlannerVisionError.disabled }
                try assertVisualBudget(for: .groupRename)
                try actionGate(.renameGroup, target.title)
                try assertVisualBudget(for: .groupRename)
            }
            func sameTarget() throws {
                let current = try self.reader()
                let currentWindow = current.layout.window
                let rows = try current.conversations().filter(\.selected)
                guard currentWindow.backend === window.backend,
                      currentWindow.handle == window.handle, try currentWindow.pid() == pid,
                      try app.pid() == pid, try app.role() == AXRole.application,
                      try currentWindow.role() == AXRole.window,
                      try currentWindow.subrole() == "AXStandardWindow",
                      let currentFrame = try currentWindow.frame(),
                      abs(currentFrame.minX - frame.minX) <= 2, abs(currentFrame.minY - frame.minY) <= 2,
                      abs(currentFrame.width - frame.width) <= 2, abs(currentFrame.height - frame.height) <= 2,
                      try app.element(AXAttribute.mainWindow)?.handle == window.handle,
                      try app.element(AXAttribute.focusedWindow)?.handle == window.handle,
                      rows.count == 1, rows[0].handle == rowHandle, rows[0].title == target.title,
                      try AXElement(handle: rowHandle, backend: currentWindow.backend).pid() == pid,
                      try current.activeConversationHeader()?.title == target.title else {
                    throw AIPlannerVisionError.staleView
                }
            }

            try gate()
            try sameTarget()
            guard try app.isSettable(AXAttribute.frontmost) else { throw AIPlannerVisionError.staleView }
            if let previous = actions.frontmostPid(), previous != pid {
                restore = { actions.restoreFrontmost(previous) }
            }
            try app.setAttribute(AXAttribute.frontmost, to: .bool(true))
            let visible = try actions.waitUntil {
                try gate()
                let handles = try windowHandles()
                // An AX reply may itself coincide with a view or permission
                // change, so recheck after it, including the final poll.
                try gate()
                try sameTarget()
                guard handles.isEmpty || handles.filter({ $0 == window.handle }).count == 1 else {
                    throw AIPlannerVisionError.staleView
                }
                let frontmost = try app.bool(AXAttribute.frontmost)
                return !handles.isEmpty && frontmost == true
            }
            guard visible else { throw AIPlannerVisionError.staleView }
            try gate()
            try sameTarget()
        } catch let error as AIPlannerVisionError {
            throw visualEnded("group title window preparation: \(error)", outcome: error.logName)
        }
        // Keep foreground ownership through the entire original action. Its
        // own draft recovery and B37/B55 checks finish before focus is returned.
        return try body(window)
    }
}
