import AXKit
import ControlCore
import Foundation

extension WeComActions {
    /// The desktop step of an enterprise broadcast: after `add_msg_template`
    /// the client shows a 群发助手 task that a human normally sends. This looks
    /// for a pending assistant sheet/window displaying the exact API msgid and
    /// a single send button, presses it once (`AXPress`), and verifies that
    /// the button went away or got disabled. A generic assistant panel cannot
    /// be correlated to msgid; without that evidence this fails before the
    /// irreversible checkpoint instead of risking a different pending task.
    /// Shape of the real 群发助手 window remains unverified live.
    public func confirmBroadcast(reader: WeComReader, msgid: String?, hooks: SubmitHooks = SubmitHooks()) throws -> ActionOutcome {
        try authorize(.confirmBroadcast, title: nil)
        guard let msgid, !msgid.isEmpty else {
            throw ActionError.actionUnavailable("群发助手 msgid 未核对")
        }
        let originalPID = try reader.layout.window.pid()
        let originalFrame = try reader.layout.window.frame()
        func soleTask() throws -> (window: AXElement, panel: AXElement, button: AXElement) {
            guard originalPID > 0, try reader.layout.window.pid() == originalPID,
                  try reader.layout.window.frame() == originalFrame else {
                throw ActionError.actionUnavailable("群发助手窗口已变化")
            }
            let roots = [reader.layout.window] + (try otherWindows(reader))
            var matched: [(window: AXElement, panel: AXElement, button: AXElement)] = []
            for root in roots {
                guard try root.role() == AXRole.window,
                      try root.pid() == originalPID,
                      let windowFrame = try root.frame(),
                      windowFrame.width > 0, windowFrame.height > 0 else {
                    throw ActionError.actionUnavailable("群发助手窗口已变化")
                }
                let panels = root.handle == reader.layout.window.handle
                    ? root.descendants(maxDepth: 8, maxNodes: 1000).filter { (try? $0.role()) == AXRole.sheet }
                    : [root]
                for panel in panels {
                    let nodes = panel.descendants(maxDepth: 14, maxNodes: 4000)
                    guard nodes.contains(where: { node in
                        (try? node.role()) == AXRole.staticText && ((try? node.valueString()) ?? "").contains("群发")
                    }), nodes.contains(where: { node in
                        (try? node.role()) == AXRole.staticText && (try? node.valueString()) == msgid
                    }) else { continue }
                    let buttons = nodes.filter { node in
                        (try? node.role()) == AXRole.button
                            && (Self.looksLikeSend(try? node.title()) || Self.looksLikeSend(try? node.axDescription()))
                    }
                    guard buttons.count == 1, try buttons[0].isEnabled() == true,
                          try buttons[0].actions().contains(AXAction.press),
                          let buttonFrame = try buttons[0].frame(),
                          buttonFrame.width > 0, buttonFrame.height > 0,
                          windowFrame.intersects(buttonFrame) else {
                        throw ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")
                    }
                    matched.append((root, panel, buttons[0]))
                }
            }
            guard matched.count == 1 else {
                throw ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")
            }
            return matched[0]
        }
        let task = try soleTask()
        let taskWindowFrame = try task.window.frame()
        let taskButtonFrame = try task.button.frame()
        func sameTask() throws -> Bool {
            let fresh = try soleTask()
            let sameWindowFrame = try fresh.window.frame() == taskWindowFrame
            let sameButtonFrame = try fresh.button.frame() == taskButtonFrame
            return fresh.window.handle == task.window.handle &&
                fresh.panel.handle == task.panel.handle &&
                fresh.button.handle == task.button.handle &&
                sameWindowFrame && sameButtonFrame
        }
        let label = (try? task.button.title()) ?? (try? task.button.axDescription()) ?? ""
        try visualObserveBroadcastConfirm?(reader, task.window, task.panel, task.button,
                                            msgid, .beforePress, { try sameTask() })
        try authorize(.confirmBroadcast, title: nil)
        guard try sameTask() else {
            throw ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")
        }
        try hooks.beforeIrreversible()
        try visualBroadcastConfirmPressGate?(task.window, task.panel, task.button,
                                             msgid, { try sameTask() })
        guard try sameTask() else {
            throw ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")
        }
        try task.button.perform(AXAction.press)
        try hooks.afterIrreversible()
        let gone = try waitUntil {
            if (try? task.button.isEnabled()) == false { return true }
            return !task.panel.descendants(maxDepth: 14, maxNodes: 4000).contains { $0.handle == task.button.handle }
        }
        // A disappearing or disabled button is sufficient AX proof. If the
        // original live task still exposes its enabled button, a new image may
        // veto an uncertain result, but cannot convert failed AX proof to success.
        if !gone, (try? sameTask()) == true {
            try visualObserveBroadcastConfirm?(reader, task.window, task.panel, task.button,
                                                msgid, .afterPress, { try sameTask() })
        }
        return ActionOutcome(kind: ActionKind.confirmBroadcast.rawValue, target: nil, verified: gone,
                             details: ["msgid": msgid, "button": label])
    }

    private func otherWindows(_ reader: WeComReader) throws -> [AXElement] {
        let pid = try reader.layout.window.pid()
        let app = AXApp.byPID(pid, backend: reader.layout.window.backend)
        // A window-rooted fake represents exactly one window. A live process
        // must enumerate every window or global msgid uniqueness is unknown.
        if reader.layout.window.backend.name == "fake", try app.role() == AXRole.window,
           app.handle == reader.layout.window.handle { return [] }
        guard try app.role() == AXRole.application else {
            throw ActionError.actionUnavailable("群发助手窗口已变化")
        }
        // Do not use the convenience `elements` getter here: it converts an
        // unsupported AXWindows attribute into an empty array, which would
        // falsely make the requested msgid globally unique.
        guard let handles = try app.attribute(AXAttribute.windows)?.elementsValue,
              handles.contains(reader.layout.window.handle) else {
            throw ActionError.actionUnavailable("群发助手窗口已变化")
        }
        return handles.filter { $0 != reader.layout.window.handle }
            .map { AXElement(handle: $0, backend: reader.layout.window.backend) }
    }
}
