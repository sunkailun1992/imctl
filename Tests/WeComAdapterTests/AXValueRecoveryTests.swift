import CoreGraphics
import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("Transient message AXValue reads")
struct AXValueRecoveryTests {
    private static func fixture() -> (FakeAXBackend, AXElement, CGRect, AXElementHandle) {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let text = AXNode(role: AXRole.textArea, value: .string("sample"),
                          frame: CGRect(x: 15, y: 20, width: 80, height: 20))
        let cell = AXNode(role: AXRole.cell, frame: frame, children: [text])
        let row = AXNode(role: AXRole.row, frame: frame, children: [cell])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.table, frame: frame, children: [row]))
        return (fake, fake.rootElement, frame, fake.handle(atPath: [0, 0, 0])!)
    }

    @Test func oneTransientAXFailureRecoversTheText() throws {
        let (fake, table, frame, textHandle) = Self.fixture()
        var reads = 0
        fake.onRead = { handle, attribute in
            guard handle == textHandle, attribute == AXAttribute.value else { return }
            reads += 1
            fake.injectedFailures["get:AXValue"] = reads == 1
                ? .apiFailure(code: -25201, operation: "get AXValue") : nil
        }
        let row = try #require(MessageRowParser().parse(table: table, tableFrame: frame).first)
        #expect(reads == 2)
        #expect(row.kind == .message && row.text == "sample" && row.readError == nil)
    }

    @Test func persistentAXFailureKeepsAnExplicitPartialTextRow() throws {
        let (fake, table, frame, textHandle) = Self.fixture()
        var reads = 0
        fake.onRead = { handle, attribute in
            guard handle == textHandle, attribute == AXAttribute.value else { return }
            reads += 1
            fake.injectedFailures["get:AXValue"] = .apiFailure(code: -25201, operation: "get AXValue")
        }
        let row = try #require(MessageRowParser().parse(table: table, tableFrame: frame).first)
        #expect(reads == 2)
        #expect(row.kind == .message && row.text == nil && row.mediaType == nil)
        #expect(row.readError == "AX_VALUE_UNAVAILABLE")
    }

    @Test func otherAXFailuresStillPropagate() throws {
        let (fake, table, frame, _) = Self.fixture()
        fake.injectedFailures["get:AXValue"] = .apiFailure(code: -25204, operation: "get AXValue")
        #expect(throws: AXKitError.apiFailure(code: -25204, operation: "get AXValue")) {
            try MessageRowParser().parse(table: table, tableFrame: frame)
        }
    }

    @Test func partialHistoryHasNoUnstableKeysAndCannotPublishWatchEvents() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        func row(_ text: String, y: CGFloat) -> AXNode {
            AXNode(role: AXRole.row, frame: CGRect(x: 311, y: y, width: 1609, height: 50), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 50), children: [
                    AXNode(role: AXRole.textArea, value: .string(text), frame: CGRect(x: 380, y: y + 8, width: 120, height: 20)),
                ]),
            ])
        }
        fake.replaceChildren(of: table, with: [row("first", y: 130), row("second", y: 180)])
        let firstText = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0, 0, 0, 0]))
        fake.onRead = { handle, attribute in
            guard attribute == AXAttribute.value else { return }
            fake.injectedFailures["get:AXValue"] = handle == firstText
                ? .apiFailure(code: -25201, operation: "get AXValue") : nil
        }
        let reader = try WeComReader(window: fake.rootElement)
        let messages = try reader.chatMessages()
        #expect(messages.count == 2)
        #expect(messages[0].readError == "AX_VALUE_UNAVAILABLE")
        #expect(messages[0].messageKey == nil && messages[1].messageKey == nil)
        #expect(throws: WeComError.region("incomplete message AXValue")) {
            try WatchSnapshot.take(reader)
        }
    }
}
