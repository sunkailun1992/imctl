import Testing
@testable import AXKit

@Suite("AXObserving (fake)")
struct AXObservingTests {
    @Test func fakeDeliversOnlySubscribedPairs() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        var got: [AXNotificationEvent] = []
        let observer = try fake.makeObserver(pid: fake.pid) { got.append($0) }
        let table = try #require(fake.handle(atPath: [0, 0]))
        try observer.add(AXNotification.rowCountChanged, to: table)
        fake.emit(AXNotification.rowCountChanged, on: table)
        fake.emit(AXNotification.valueChanged, on: table)
        fake.emit(AXNotification.rowCountChanged, on: fake.rootHandle)
        #expect(got.map(\.name) == [AXNotification.rowCountChanged])
        #expect(got.first?.element == table)
        try observer.remove(AXNotification.rowCountChanged, from: table)
        fake.emit(AXNotification.rowCountChanged, on: table)
        #expect(got.count == 1)
    }
}
