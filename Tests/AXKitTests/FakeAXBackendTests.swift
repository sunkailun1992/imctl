import CoreGraphics
import Foundation
import Testing
@testable import AXKit

enum SampleTree {
    static func make() -> AXNode {
        AXNode(role: AXRole.application, title: "SampleApp", children: [
            AXNode(role: AXRole.window, title: "Main", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
                AXNode(role: AXRole.table, identifier: "conversations", settable: [AXAttribute.selectedRows], extra: ["AXSelectedRows": "<0 elements>"], children: [
                    AXNode(role: AXRole.row, title: "Row A", selected: true, actions: [AXAction.press]),
                    AXNode(role: AXRole.row, title: "Row B", selected: false, actions: [AXAction.press]),
                ]),
                AXNode(role: AXRole.textArea, value: .string(""), placeholder: "Type here", actions: [], settable: [AXAttribute.value]),
                AXNode(role: AXRole.button, title: "Send", enabled: false, actions: [AXAction.press]),
            ]),
        ])
    }
}

@Suite("FakeAXBackend")
struct FakeAXBackendTests {
    @Test func readsMappedAttributesAndChildren() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let root = fake.rootElement
        #expect(try root.role() == AXRole.application)
        #expect(try root.title() == "SampleApp")
        let window = try #require(try root.children().first)
        #expect(try window.frame() == CGRect(x: 0, y: 0, width: 800, height: 600))
        let table = try #require(fake.element(atPath: [0, 0]))
        #expect(try table.identifier() == "conversations")
        #expect(try table.children().count == 2)
        #expect(try table.parent()?.handle == window.handle)
        #expect(try table.string("AXSelectedRows") == "<0 elements>")
        #expect(try fake.element(atPath: [0, 0, 0])?.isSelected() == true)
        #expect(try fake.element(atPath: [0, 2])?.isEnabled() == false)
        #expect(try root.pid() == 4242)
    }

    @Test func missingAttributeThrowsUnsupported() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        #expect(throws: AXKitError.attributeUnsupported("AXURL")) {
            try fake.rootElement.attribute("AXURL")
        }
    }

    @Test func setAttributeRecordsAndUpdatesOnlyWhenSettable() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let input = try #require(fake.element(atPath: [0, 1]))
        #expect(try input.isSettable(AXAttribute.value))
        try input.setAttribute(AXAttribute.value, to: .string("hello"))
        #expect(try input.valueString() == "hello")
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].attribute == AXAttribute.value)
        #expect(fake.recordedSets[0].value == .string("hello"))

        let button = try #require(fake.element(atPath: [0, 2]))
        #expect(throws: AXKitError.attributeNotSettable(AXAttribute.title)) {
            try button.setAttribute(AXAttribute.title, to: .string("x"))
        }
        #expect(fake.recordedSets.count == 1)
    }

    @Test func performRecordsOnlySupportedActions() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let button = try #require(fake.element(atPath: [0, 2]))
        #expect(try button.actions() == [AXAction.press])
        try button.perform(AXAction.press)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
        let input = try #require(fake.element(atPath: [0, 1]))
        #expect(throws: AXKitError.actionUnsupported(AXAction.press)) { try input.perform(AXAction.press) }
        #expect(fake.recordedActions.count == 1)
    }

    @Test func injectedFailuresAreThrown() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.injectedFailures["get:AXTitle"] = .cannotComplete("get AXTitle")
        #expect(throws: AXKitError.cannotComplete("get AXTitle")) { try fake.rootElement.title() }
        #expect(try fake.rootElement.role() == AXRole.application)
        fake.injectedFailures["get:*"] = .invalidElement
        #expect(throws: AXKitError.invalidElement) { try fake.rootElement.role() }
    }

    @Test func mutateAndReplaceChildrenChangeTreeWithoutRecording() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let table = try #require(fake.handle(atPath: [0, 0]))
        fake.replaceChildren(of: table, with: [AXNode(role: AXRole.row, title: "Row C")])
        let rows = try fake.rootElement.children()[0].children()[0].children()
        #expect(try rows.map { try $0.title() } == ["Row C"])
        fake.mutate(rows[0].handle, attribute: AXAttribute.title, to: .string("Row C'"))
        #expect(try rows[0].title() == "Row C'")
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func reactionsRunAfterSuccessfulActionsAndSets() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let button = try #require(fake.handle(atPath: [0, 2]))
        let input = try #require(fake.handle(atPath: [0, 1]))
        fake.reactions["action:AXPress"] = { fake.mutate(input, attribute: AXAttribute.value, to: .string("pressed")) }
        try AXElement(handle: button, backend: fake).perform(AXAction.press)
        #expect(try AXElement(handle: input, backend: fake).valueString() == "pressed")
        fake.setActions(of: input, to: [AXAction.confirm])
        #expect(try AXElement(handle: input, backend: fake).actions() == [AXAction.confirm])
    }

    @Test func trustedFlagIsReported() {
        #expect(FakeAXBackend(root: SampleTree.make(), trusted: false).isProcessTrusted(prompt: true) == false)
    }
}

@Suite("AXNode")
struct AXNodeTests {
    @Test func codableRoundTripAndCounts() throws {
        let node = SampleTree.make()
        let data = try JSONEncoder().encode(node)
        let back = try JSONDecoder().decode(AXNode.self, from: data)
        #expect(back == node)
        #expect(node.count == 7)
        #expect(node.maxDepth == 3)
        #expect(node.first { $0.role == AXRole.button }?.title == "Send")
    }

    @Test func valueEncodesAsTaggedObject() throws {
        let json = String(decoding: try JSONEncoder().encode(AXNodeValue.bool(true)), as: UTF8.self)
        #expect(json == #"{"bool":true}"#)
        let s = try JSONDecoder().decode(AXNodeValue.self, from: Data(#"{"string":"hi"}"#.utf8))
        #expect(s == .string("hi"))
    }

    @Test func applicationNodeDerivesItsWindowsFromChildren() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let app = fake.rootElement
        #expect(try app.element(AXAttribute.mainWindow)?.title() == "Main")
        #expect(try app.element(AXAttribute.focusedWindow)?.title() == "Main")
        #expect(try app.elements(AXAttribute.windows).count == 1)
        let window = try #require(fake.element(atPath: [0]))
        #expect(try window.attributeIfSupported(AXAttribute.mainWindow) == nil)
    }
}
