import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("fixed command visual candidate gates")
struct AIPlannerActionTests {
    private func ambiguousTitleFixture() throws -> (FakeAXBackend, WeComReader, AXElement) {
        let fake = try Fixtures.mainWindow()
        let cellHandle = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0]))
        let row = try #require(fake.element(atPath: [0, 33, 2, 0, 2]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let children = source.children[0].children[33].children[2].children[0].children[2].children[0].children
        // The parser picks the leftmost top-band static text; the actual title remains an
        // exact, unique text in the row. This simulates a newly inserted client badge.
        let badge = AXNode(role: AXRole.staticText, value: .string("new badge"),
                           frame: CGRect(x: 100, y: 140, width: 28, height: 20))
        fake.replaceChildren(of: cellHandle, with: [badge] + children)
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.conversations().filter { $0.title == "文件传输助手" }.isEmpty)
        return (fake, reader, row)
    }

    private func candidate(_ element: AXElement, kind: AIPlannerCandidateKind) throws -> AIPlannerCandidate {
        let frame = try #require(try element.frame())
        return AIPlannerCandidate(id: "C0", kind: kind, element: element,
                                  role: try element.role() ?? "", frame: frame)
    }

    @Test func exactAXConversationTitleDoesNotCallVisualModel() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("exact AX title must use the fast path"); return nil }
        let out = try actions.selectConversation("文件传输助手", reader: reader)
        #expect(out.verified && fake.recordedSets.count == 1)
    }

    @Test func parserMissUsesOnlyUniqueExactAXRowAndVerifiesHeader() throws {
        let (fake, reader, row) = try ambiguousTitleFixture()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        var called = 0
        actions.visualSelect = { _, goal, kinds, expectedTitle, eligible, _ in
            called += 1
            if case .conversationRow(let title) = goal { #expect(title == "文件传输助手") }
            else { Issue.record("wrong visual goal") }
            #expect(kinds == [.selectRow] && expectedTitle == nil)
            #expect(eligible.map(\.handle) == [row.handle])
            return try candidate(row, kind: .selectRow)
        }
        let out = try actions.selectConversation("文件传输助手", reader: reader)
        #expect(out.verified && called == 1)
        #expect(fake.recordedSets.count == 1 && fake.recordedSets[0].value == .elements([row.handle]))
    }

    @Test func modelCannotSelectOtherConversationRow() throws {
        let (fake, reader, _) = try ambiguousTitleFixture()
        let wrong = try #require(fake.element(atPath: [0, 33, 2, 0, 3]))
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        actions.visualSelect = { _, _, _, _, _, _ in try candidate(wrong, kind: .selectRow) }
        #expect(throws: ActionError.actionUnavailable("conversation row")) {
            try actions.selectConversation("文件传输助手", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func modelCannotActOnAStaleAXFrame() throws {
        let (fake, reader, row) = try ambiguousTitleFixture()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        actions.visualSelect = { _, _, _, _, _, _ in
            let old = try candidate(row, kind: .selectRow)
            return AIPlannerCandidate(id: old.id, kind: old.kind, element: old.element, role: old.role,
                                      frame: old.frame.offsetBy(dx: 12, dy: 0))
        }
        #expect(throws: ActionError.actionUnavailable("conversation row")) {
            try actions.selectConversation("文件传输助手", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func policyGateRevokedAfterVisualDecisionPreventsAXWrite() throws {
        let (fake, reader, row) = try ambiguousTitleFixture()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        var revoked = false
        var gateCalls = 0
        actions.visualActionGate = { kind, title in
            gateCalls += 1
            #expect(kind == .selectConversation && title == "文件传输助手")
            if revoked { throw AIPlannerVisionError.disabled }
        }
        actions.visualSelect = { _, _, _, _, _, gate in
            try gate()
            revoked = true
            return try candidate(row, kind: .selectRow)
        }
        #expect(throws: AIPlannerVisionError.disabled) {
            try actions.selectConversation("文件传输助手", reader: reader)
        }
        #expect(gateCalls >= 3 && fake.recordedSets.isEmpty)
    }

    @Test func parserFastPathRejectsAnotherRawRowWithSameExactTitle() throws {
        let fake = try Fixtures.mainWindow()
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        var children = source.children[0].children[33].children[2].children[0].children[1].children[0].children
        let titleIndex = try #require(children.firstIndex {
            $0.role == AXRole.staticText && $0.frame?.y == 76
        })
        children[titleIndex].value = .string("文件传输助手")
        children.insert(AXNode(role: AXRole.staticText, value: .string("new badge"),
                               frame: CGRect(x: 100, y: 76, width: 28, height: 20)), at: 0)
        let cell = try #require(fake.handle(atPath: [0, 33, 2, 0, 1, 0]))
        fake.replaceChildren(of: cell, with: children)
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.conversations().filter { $0.title == "文件传输助手" }.count == 1)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("duplicate target must stop before model call"); return nil }
        #expect(throws: ActionError.targetAmbiguous("文件传输助手", count: 2)) {
            try actions.selectConversation("文件传输助手", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func visualRowWithoutExactAXTitleIsRejectedBeforeModelCall() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["missing"], enabled: [.selectConversation]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("no eligible row should not call model"); return nil }
        #expect(throws: ActionError.targetNotFound("missing")) {
            try actions.selectConversation("missing", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }
}
