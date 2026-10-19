import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("WeComObserver on fake")
struct WeComObserverTests {
    @Test func subscribesStandardSetAndDeliversTableNotifications() throws {
        let fake = try Fixtures.mainWindow()
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        var got: [String] = []
        let sub = try WeComObserver.subscribe(to: layout) { got.append($0.name) }
        #expect(sub.added >= 20 && sub.unsupported.isEmpty)
        fake.emit(AXNotification.rowCountChanged, on: layout.conversationTable.handle)
        fake.emit(AXNotification.rowCountChanged, on: try #require(layout.messageTable).handle)
        fake.emit(AXNotification.valueChanged, on: try #require(layout.composer).handle)
        #expect(got == [AXNotification.rowCountChanged, AXNotification.rowCountChanged, AXNotification.valueChanged])
        sub.observer.stop()
        fake.emit(AXNotification.rowCountChanged, on: layout.conversationTable.handle)
        #expect(got.count == 3)
    }

    @Test func layoutWithoutMessageTableSubscribesFewerTargets() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-main-window.json")))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(layout.messageTable == nil)
        let sub = try WeComObserver.subscribe(to: layout) { _ in }
        #expect(sub.added == WeComObserver.applicationNotifications.count + WeComObserver.windowNotifications.count
                + WeComObserver.conversationTableNotifications.count + (layout.composer == nil ? 0 : 1))
    }
}
