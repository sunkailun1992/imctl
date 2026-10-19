import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// Application root = the main-window fixture plus a 窗口 menu, as the live
/// client exposes it: the items are disabled until the app is frontmost.
enum NavigateFixture {
    static func app(itemsEnabled: Bool = false) throws -> FakeAXBackend {
        let window = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        func item(_ t: String) -> AXNode { AXNode(role: AXRole.menuItem, title: t, enabled: itemsEnabled, actions: [AXAction.press]) }
        let menu = AXNode(role: AXRole.menu, children: [item("最小化"), item("选择下一个会话"), item("选择上一个会话"), item("选择下一个未读会话")])
        let bar = AXNode(role: AXRole.menuBar, children: [
            AXNode(role: AXRole.menuBarItem, title: "文件", children: [AXNode(role: AXRole.menu, children: [item("关闭")])]),
            AXNode(role: AXRole.menuBarItem, title: "窗口", children: [menu]),
        ])
        return FakeAXBackend(root: AXNode(role: AXRole.application, title: "企业微信", settable: [AXAttribute.frontmost], children: [window, bar]))
    }

    /// Path of the active-title static text inside the app root (the window is child 0).
    static let headerPath = [0, 0, 33, 5]
    /// 窗口 › 选择下一个会话 inside the app root (menu bar is child 1).
    static let nextItemPath = [1, 1, 0, 1]

    /// Client behaviour: menu items validate once the app is frontmost.
    static func enableItemsWhenFrontmost(_ fake: FakeAXBackend) {
        fake.reactions["set:\(AXAttribute.frontmost)"] = {
            for index in 0..<4 {
                if let h = fake.handle(atPath: [1, 1, 0, index]) { fake.mutate(h, attribute: AXAttribute.enabled, to: .bool(true)) }
            }
        }
    }
}

final class FocusLog {
    var restored: [pid_t] = []
}

@Suite("client.navigate via the 窗口 menu")
struct NavigateTests {
    let policy = ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.navigate])

    func actions(_ log: FocusLog, previous: pid_t? = 777) -> WeComActions {
        var a = WeComActions(policy: policy)
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01
        a.frontmostPid = { previous }
        a.restoreFrontmost = { log.restored.append($0) }
        return a
    }

    @Test func menuBarListsWindowMenuItemsWithEnabledFlags() throws {
        let fake = try NavigateFixture.app()
        let items = try WeComMenuBar.items(in: fake.rootElement, menu: "窗口")
        #expect(items.map(\.title) == ["最小化", "选择下一个会话", "选择上一个会话", "选择下一个未读会话"])
        #expect(items.allSatisfy { $0.enabled == false })
        let window = try #require(fake.element(atPath: [0]))
        #expect(throws: WeComError.region("menuBar")) { try WeComMenuBar.items(in: window, menu: "窗口") }
        #expect(throws: WeComError.region("menu 窗口 › 不存在")) { try WeComMenuBar.menuItem(in: fake.rootElement, menu: "窗口", item: "不存在") }
    }

    @Test func navigateMakesTheClientFrontmostPressesAndGivesFocusBack() throws {
        let fake = try NavigateFixture.app()
        NavigateFixture.enableItemsWhenFrontmost(fake)
        let header = try #require(fake.handle(atPath: NavigateFixture.headerPath))
        fake.reactions["action:AXPress"] = { fake.mutate(header, attribute: AXAttribute.value, to: .string("someone")) }
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        let log = FocusLog()
        let out = try actions(log).navigate(.nextConversation, app: fake.rootElement, reader: reader)
        #expect(out.kind == "navigate" && out.verified)
        #expect(out.details == ["action": "nextConversation", "before": "文件传输助手", "after": "someone", "changed": "true", "enabled": "true"])
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.frontmost] && fake.recordedSets[0].value == .bool(true))
        #expect(fake.recordedSets[0].handle == fake.rootHandle)
        #expect(fake.recordedActions.count == 1 && fake.recordedActions[0].action == AXAction.press)
        #expect(fake.recordedActions[0].handle == fake.handle(atPath: NavigateFixture.nextItemPath))
        #expect(log.restored == [777])
    }

    @Test func navigateWithoutAChangeIsNotAnErrorAndStaysDisabledWhenTheClientDoesNotValidate() throws {
        let fake = try NavigateFixture.app()   // no reaction: the items never become enabled
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        let log = FocusLog()
        let out = try actions(log, previous: fake.pid).navigate(.nextUnreadConversation, app: fake.rootElement, reader: reader)
        #expect(out.details["changed"] == "false" && out.details["enabled"] == "false")
        #expect(out.details["before"] == "文件传输助手" && out.details["after"] == "文件传输助手")
        #expect(fake.recordedActions.isEmpty)   // a disabled item is never pressed
        #expect(log.restored.isEmpty)   // the client itself had focus: nothing to give back
    }

    @Test func navigateIsRefusedByPolicyBeforeAnyAX() throws {
        let fake = try NavigateFixture.app()
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(throws: PolicyError.notEnabled(.navigate)) {
            try WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"])).navigate(.nextConversation, app: fake.rootElement, reader: reader)
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func missingMenuItemIsActionUnavailableBeforeTouchingFocus() throws {
        let window = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, settable: [AXAttribute.frontmost], children: [window, AXNode(role: AXRole.menuBar)]))
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        let log = FocusLog()
        #expect(throws: ActionError.actionUnavailable("menu 窗口 › 选择下一个会话")) {
            try actions(log).navigate(.nextConversation, app: fake.rootElement, reader: reader)
        }
        #expect(fake.recordedSets.isEmpty && log.restored.isEmpty)
    }
}
