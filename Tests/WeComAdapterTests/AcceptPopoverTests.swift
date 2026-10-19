import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("Accept popover")
struct AcceptPopoverTests {
    @Test func doneButtonIsFoundInTheSecondaryWindowOnly() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-accept-popover.json")))
        let app = fake.rootElement
        let main = try #require(try app.children().first { (try? $0.role()) == AXRole.window && ((try? $0.frame())??.width ?? 0) > 1000 })
        #expect(WeComContactsView.isShowing(window: main))
        let done = try #require(try WeComAcceptPopover.doneButton(app: app, mainWindow: main))
        #expect(try done.frame()?.width == 262 && (try done.actions()).contains(AXAction.press))
        // the plain 新的客户 page (window-rooted) has no popover
        let contacts = try ContactsFixture.newCustomers()
        #expect(try WeComAcceptPopover.doneButton(app: contacts.rootElement, mainWindow: contacts.rootElement) == nil)
    }
}
