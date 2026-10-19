import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("Composer context menu on fake")
struct ComposerMenuTests {
    @Test func listsItemsAndClosesMenu() throws {
        let fake = try Fixtures.mainWindow()
        let root = fake.rootHandle
        // Fixture root is the window; the fake's applicationElement returns it too.
        fake.reactions["action:AXShowMenu"] = {
            let source = try? AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
            var children = source?.children ?? []
            children.append(AXNode(role: "AXMenu", actions: ["AXCancel"], children: [
                AXNode(role: "AXMenuItem", title: "剪切", actions: ["AXPress"]),
                AXNode(role: "AXMenuItem", title: "粘贴", enabled: false, actions: ["AXPress"]),
            ]))
            fake.replaceChildren(of: root, with: children)
        }
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.showComposerMenu]))
        let report = try actions.inspectComposerMenu(reader: reader, settle: 0.01)
        #expect(report.menuFound)
        #expect(report.items == ["剪切", "粘贴 [disabled]"])
        #expect(report.closeMethod == "AXCancel")
        #expect(fake.recordedActions.map(\.action) == ["AXShowMenu", "AXCancel"])
    }

    @Test func requiresEnableFlag() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        #expect(throws: PolicyError.notEnabled(.showComposerMenu)) {
            try WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"])).inspectComposerMenu(reader: reader, settle: 0.01)
        }
    }
}
