import CoreGraphics
import Foundation
@testable import AXKit

/// A synthetic main window with a group chat active. Geometry copies the
/// 5.0.11 recording (conversation table x 59–311, message table x 310 wide
/// 1611, header text at y 20, message scroll area from y 64); no real
/// contact content, so it can live in the repo. Row shapes (sender label
/// above the bubble, centered system notices) are the assumption B4 live
/// checks calibrate against the user's test group.
enum GroupFixture {
    static let groupTitle = "imctl测试群"
    static let customerTitle = "小明·a1b2c3"

    static func text(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat = 80, h: CGFloat = 18) -> AXNode {
        AXNode(role: AXRole.staticText, value: .string(s), frame: CGRect(x: x, y: y, width: w, height: h))
    }

    static func conversationRow(y: CGFloat, title: String, preview: String, time: String, marker: String? = nil, badge: String? = nil, selected: Bool = false) -> AXNode {
        var kids = [
            AXNode(role: AXRole.image, description: "", frame: CGRect(x: 75, y: y + 11, width: 42, height: 42)),
            text(title, x: 129, y: y + 12, w: 86, h: 20),
            text(preview, x: 129, y: y + 33, w: 124),
            AXNode(role: AXRole.group, frame: CGRect(x: 76, y: y + 63, width: 218, height: 1)),
            text(time, x: 255, y: y + 33, w: 38),
        ]
        if let marker { kids.append(text(marker, x: 220, y: y + 12, w: 28, h: 16)) }
        if let badge { kids.append(AXNode(role: AXRole.textArea, value: .string(badge), frame: CGRect(x: 262, y: y + 12, width: 36, height: 16))) }
        return AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 60, y: y, width: 250, height: 64), selected: selected, children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 60, y: y, width: 250, height: 64), selected: selected, children: kids),
        ])
    }

    /// Bubble row: `sender` above the body means a group message from someone else.
    static func messageRow(y: CGFloat, text body: String, sender: String? = nil, time: String? = nil, outbound: Bool = false) -> AXNode {
        var kids: [AXNode] = []
        if let time { kids.append(text(time, x: 1102, y: y + 7, w: 40)) }
        if let sender { kids.append(text(sender, x: 380, y: y + 30, w: 60, h: 16)) }
        let x: CGFloat = outbound ? 1500 : 380
        kids.append(AXNode(role: AXRole.textArea, value: .string(body), frame: CGRect(x: x, y: y + 50, width: 300, height: 20)))
        return AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 80), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 80), children: kids),
        ])
    }

    /// Centered notice without a text area ("xx joined the group", recalls).
    static func systemRow(y: CGFloat, text body: String) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 40), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 40), children: [
                text(body, x: 1000, y: y + 10, w: 230),
            ]),
        ])
    }

    static func timeRow(y: CGFloat, _ label: String) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 30), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 30), children: [text(label, x: 1102, y: y + 6, w: 40)]),
        ])
    }

    static func defaultMessages() -> [AXNode] {
        [
            timeRow(y: 64, "9:18"),
            systemRow(y: 94, text: "«a1»加入群聊"),
            messageRow(y: 134, text: "大家好", sender: "张三"),
            messageRow(y: 214, text: "收到", outbound: true),
            messageRow(y: 294, text: "收到", sender: "李四"),
            messageRow(y: 374, text: "收到", sender: "李四"),
        ]
    }

    /// `addMemberButtons` reproduces the header band recorded 2026-09-23 on 5.0.11: two untitled
    /// 30×30 `AXButton`s at the right edge of a 1920-wide window (x 1839 / 1879), siblings of the
    /// title and on its own y band — the rightmost one opens 添加群成员. `labelledHeaderButtons` adds
    /// the two controls the same band may also hold and that `headerButtons` must NOT return: one
    /// carrying an `AXTitle` at x 1890 — rightmost, so it would be pressed first if the title were
    /// not checked — and one carrying an `AXDescription` at x 1809. `sheet` hangs a sheet off the
    /// window the way the client does, so `GroupPickerSheet.locate` finds it. All of them are
    /// appended after the existing children, so the paths below keep pointing at the same nodes.
    /// `memberPanelMinX` ends the chat pane there and leaves the rest of the window to the group's side
    /// panel, the way 5.0.11 splits them (recorded 2026-09-15: message viewport x 411–1759, member
    /// table from 1760); nil keeps the chat as wide as the window.
    static func window(messages: [AXNode]? = nil, headerTitle: String = "\(groupTitle)(3)",
                       addMemberButtons: Bool = false, labelledHeaderButtons: Bool = false, sheet: AXNode? = nil,
                       memberPanelMinX: CGFloat? = nil) -> AXNode {
        let rows = messages ?? defaultMessages()
        let chatWidth: CGFloat = memberPanelMinX.map { $0 - 311 } ?? 1609
        let messageTable = AXNode(role: AXRole.table, frame: CGRect(x: 310, y: 63, width: chatWidth + 2, height: 933),
                                  settable: [AXAttribute.selectedRows, AXAttribute.focused], children: rows + [
            AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: chatWidth, height: 931)),
        ])
        let scrollArea = AXNode(role: AXRole.scrollArea, frame: CGRect(x: 311, y: 64, width: chatWidth, height: 931),
                                actions: [AXAction.scrollUpByPage, AXAction.scrollDownByPage], children: [
            messageTable,
            AXNode(role: AXRole.scrollBar, value: .number(1), frame: CGRect(x: 311 + chatWidth - 17, y: 64, width: 17, height: 931),
                   settable: [AXAttribute.value]),
        ])
        let composer = AXNode(role: AXRole.textArea, value: .string(""), frame: CGRect(x: 311, y: 1036, width: chatWidth, height: 159),
                              actions: [AXAction.showMenu], settable: [AXAttribute.value, AXAttribute.focused])
        let conversationTable = AXNode(role: AXRole.table, frame: CGRect(x: 59, y: 63, width: 252, height: 1138),
                                       settable: [AXAttribute.selectedRows, AXAttribute.focused], children: [
            conversationRow(y: 64, title: "文件传输助手", preview: "«p1»", time: "昨天"),
            conversationRow(y: 128, title: groupTitle, preview: "李四: 收到", time: "9:18", selected: true),
            conversationRow(y: 192, title: customerTitle, preview: "«p2»", time: "星期五", marker: "微信"),
            conversationRow(y: 256, title: "«ext»", preview: "«p3»", time: "星期五", marker: "外部"),
            conversationRow(y: 320, title: "同事甲", preview: "«p4»", time: "9/2"),
        ])
        let headerButtons: [AXNode] = (addMemberButtons ? [
            AXNode(role: AXRole.button, frame: CGRect(x: 1839, y: 17, width: 30, height: 30), actions: [AXAction.press]),
            AXNode(role: AXRole.button, frame: CGRect(x: 1879, y: 17, width: 30, height: 30), actions: [AXAction.press]),
        ] : []) + (labelledHeaderButtons ? [
            AXNode(role: AXRole.button, title: "群设置", frame: CGRect(x: 1890, y: 17, width: 30, height: 30), actions: [AXAction.press]),
            AXNode(role: AXRole.button, description: "more", frame: CGRect(x: 1809, y: 17, width: 30, height: 30), actions: [AXAction.press]),
        ] : [])
        return AXNode(role: AXRole.window, title: headerTitle, frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), children: [
            AXNode(role: "AXSplitGroup", frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), children: [
                AXNode(role: AXRole.scrollArea, frame: CGRect(x: 59, y: 63, width: 252, height: 1138), children: [conversationTable]),
                text(headerTitle, x: 326, y: 20, w: 140, h: 24),
                AXNode(role: AXRole.group, frame: CGRect(x: 310, y: 63, width: chatWidth + 2, height: 1137), children: [
                    scrollArea,
                    AXNode(role: AXRole.group, frame: CGRect(x: 311, y: 996, width: chatWidth, height: 40)),
                    AXNode(role: AXRole.group, frame: CGRect(x: 311, y: 1036, width: chatWidth, height: 159), children: [composer]),
                ]),
            ] + headerButtons),
        ] + (sheet.map { [$0] } ?? []))
    }

    static func backend(messages: [AXNode]? = nil, headerTitle: String = "\(groupTitle)(3)") -> FakeAXBackend {
        FakeAXBackend(root: window(messages: messages, headerTitle: headerTitle))
    }

    /// Paths inside `window()` for tests that mutate the fake.
    static let messageTablePath = [0, 2, 0, 0]
    static let groupRowPreviewPath = [0, 0, 0, 1, 0, 2]
}
