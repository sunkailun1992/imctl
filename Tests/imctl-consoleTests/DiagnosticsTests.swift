import Foundation
import Testing
@testable import AXKit
@testable import imctl_console

@Suite("Diagnostics on fixture")
struct DiagnosticsTests {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ax-trees")
    }

    @Test func fillsLayoutAndMenuFactsFromAnApplicationRoot() throws {
        let window = try AXNode.load(from: Self.fixtures.appendingPathComponent("wecom-5.0.10-main-window.json"))
        let menu = AXNode(role: AXRole.menu, children: [AXNode(role: AXRole.menuItem, title: "选择下一个会话", enabled: false, actions: [AXAction.press])])
        let bar = AXNode(role: AXRole.menuBar, children: [AXNode(role: AXRole.menuBarItem, title: "窗口", children: [menu])])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [window, bar]))
        let report = try Diagnostics.fill(DiagnosticsReport(consoleTrusted: true, clientRunning: true), app: fake.rootElement)
        #expect(report.activeTitle == "文件传输助手" && report.conversationCount == 6 && report.composerPresent == true)
        #expect(report.rowHeights == [64] && report.windowMenuItems == ["选择下一个会话 [disabled]"])
        #expect(report.conversationTable?.hasPrefix("(59") == true && report.error == nil)
    }
}
