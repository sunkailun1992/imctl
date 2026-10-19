import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("message.history scrollback on fake")
struct ScrollbackTests {
    static func oldRow(_ text: String) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 64, width: 1609, height: 60), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 64, width: 1609, height: 60), children: [
                AXNode(role: AXRole.textArea, value: .string(text), frame: CGRect(x: 380, y: 70, width: 90, height: 15)),
            ]),
        ])
    }

    @Test func scrollbackLoadsUntilMinRowsThenRestores() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let bar1 = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var rows = existing.children
        var loads = 0
        fake.reactions["set:AXValue"] = {
            // the first vertical bar set to 0 (top) makes the client load two older rows
            guard let last = fake.recordedSets.last, last.handle == bar1, last.value == .double(0) else { return }
            loads += 1
            rows.insert(contentsOf: [Self.oldRow("old-\(loads)-a"), Self.oldRow("old-\(loads)-b")], at: 0)
            fake.replaceChildren(of: table, with: rows)
        }
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.verifyTimeout = 0.2; actions.verifyInterval = 0.02
        let out = try actions.loadOlderMessages(reader: reader, minRows: 4)
        #expect(out.rowsBefore == 1 && out.rowsAfter == 5 && out.scrolls == 2 && out.restored)
        #expect(try reader.messages().count == 5)
        #expect(try reader.messages().first?.text == "old-2-a")
        #expect(fake.recordedSets.last?.value == .double(1))
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func scrollbackStopsWhenNothingLoadsAndRefusesUnlistedConversation() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory], sendPolicy: SendPolicy(gateReads: true)))
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        let out = try actions.loadOlderMessages(reader: reader, minRows: 10, maxScrolls: 5)
        #expect(out.rowsAfter == 1 && out.scrolls == 2)
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.mutate(title, attribute: AXAttribute.value, to: .string("someone"))
        let r2 = try WeComReader(window: fake.rootElement)
        let before = fake.recordedSets.count
        #expect(throws: PolicyError.targetNotAllowed("someone")) { try actions.loadOlderMessages(reader: r2, minRows: 3) }
        #expect(fake.recordedSets.count == before)
    }

    @Test func pageStrategyUsesActionsInsteadOfBars() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        let out = try actions.loadOlderMessages(reader: reader, minRows: 3, maxScrolls: 5, strategy: .pageAction)
        #expect(out.scrolls == 2 && fake.recordedSets.isEmpty)
        #expect(fake.recordedActions.map(\.action) == Array(repeating: AXAction.scrollUpByPage, count: 6) + Array(repeating: AXAction.scrollDownByPage, count: 6))
    }

    @Test func scrollbackIsRefusedWhenNotEnabled() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]))
        #expect(throws: PolicyError.notEnabled(.scrollHistory)) { try actions.loadOlderMessages(reader: reader, minRows: 3) }
    }

    @Test func ambiguousVerticalBarsUseOnlyTheVisualChoice() throws {
        let fake = try Fixtures.mainWindow()
        let area = try #require(fake.handle(atPath: [0, 33, 6, 0, 0]))
        let first = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        let secondHandle = try #require(fake.appendChild(to: area, node: AXNode(
            role: AXRole.scrollBar, value: .number(0),
            frame: CGRect(x: 1904, y: 63, width: 17, height: 892), enabled: false,
            settable: [AXAttribute.value]
        )))
        let second = AXElement(handle: secondHandle, backend: fake)
        let reader = try WeComReader(window: fake.rootElement)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        var calls = 0
        actions.visualSelect = { _, goal, kinds, title, eligible, _ in
            calls += 1
            if case .control(.messageScrollBar) = goal {} else { Issue.record("wrong scroll goal") }
            #expect(kinds == [.scroll] && title == "文件传输助手")
            #expect(eligible.count >= 2 && eligible.contains { $0.handle == secondHandle })
            return AIPlannerCandidate(id: "C1", kind: .scroll, element: second,
                                      role: AXRole.scrollBar, frame: try #require(try second.frame()))
        }
        #expect(try actions.showLatestMessages(reader: reader))
        #expect(calls == 1 && fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].handle == secondHandle && fake.recordedSets[0].handle != first)
    }

    @Test func coincidentDuplicateBarsStayOnAXFastPath() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("coincident AX bars should not upload"); return nil }
        #expect(try actions.showLatestMessages(reader: reader))
        #expect(fake.recordedSets.count == 1 && fake.recordedSets[0].value == .double(1))
    }

    @Test func innerBarDoesNotHideLatestEdgeBarOrUpload() throws {
        let fake = try Fixtures.mainWindow()
        let area = try #require(fake.handle(atPath: [0, 33, 6, 0, 0]))
        let edge = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        fake.mutate(edge, attribute: AXAttribute.value, to: .double(1))
        let inner = try #require(fake.appendChild(to: area, node: AXNode(
            role: AXRole.scrollBar, value: .number(0),
            frame: CGRect(x: 1743, y: 63, width: 17, height: 892),
            settable: [AXAttribute.value]
        )))
        let reader = try WeComReader(window: fake.rootElement)
        let action = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        let candidates = try WeComActions.messageAreaVerticalBars(
            in: try #require(reader.layout.messageScrollArea),
            settableBars: try #require(reader.layout.messageScrollArea).children().filter {
                try $0.role() == AXRole.scrollBar && $0.isSettable(AXAttribute.value)
            })
        #expect(candidates.count == 2 && !candidates.contains { $0.handle == inner })
        #expect(try action.showLatestMessages(reader: reader) == false)
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func innerBarIsNotWrittenWhenEdgeBarNeedsLatest() throws {
        let fake = try Fixtures.mainWindow()
        let area = try #require(fake.handle(atPath: [0, 33, 6, 0, 0]))
        let inner = try #require(fake.appendChild(to: area, node: AXNode(
            role: AXRole.scrollBar, value: .number(1),
            frame: CGRect(x: 1743, y: 63, width: 17, height: 892),
            settable: [AXAttribute.value]
        )))
        let reader = try WeComReader(window: fake.rootElement)
        var action = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        action.visualSelect = { _, _, _, _, _, _ in Issue.record("inner bar must not force cloud choice"); return nil }
        #expect(try action.showLatestMessages(reader: reader))
        #expect(fake.recordedSets.count == 1 && fake.recordedSets[0].handle != inner)
        #expect(fake.recordedSets[0].value == .double(1))
    }

    @Test func visualFirstScrollKeepsThePreScrollRowBaseline() throws {
        let fake = try Fixtures.mainWindow()
        let area = try #require(fake.handle(atPath: [0, 33, 6, 0, 0]))
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let second = try #require(fake.appendChild(to: area, node: AXNode(
            role: AXRole.scrollBar, value: .number(1),
            frame: CGRect(x: 1904, y: 63, width: 17, height: 892), enabled: false,
            settable: [AXAttribute.value]
        )))
        let bar = AXElement(handle: second, backend: fake)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("single-step selector must not run"); return nil }
        actions.visualScrollRounds = { _, value in
            #expect(value == 0)
            try bar.setAttribute(AXAttribute.value, to: .double(0))
            fake.replaceChildren(of: table, with: [Self.oldRow("older-a"), Self.oldRow("older-b")])
            return (bar: bar, recheck: {})
        }
        let out = try actions.loadOlderMessages(reader: WeComReader(window: fake.rootElement), minRows: 2)
        #expect(out.rowsBefore == 1 && out.rowsAfter == 2 && out.scrolls == 1 && out.restored)
        #expect(fake.recordedSets.map(\.value) == [.double(0), .double(1)])
    }

    @Test func visualRestoreMustReadBackTheLatestBarValue() throws {
        let fake = try Fixtures.mainWindow()
        let area = try #require(fake.handle(atPath: [0, 33, 6, 0, 0]))
        let second = try #require(fake.appendChild(to: area, node: AXNode(
            role: AXRole.scrollBar, value: .number(1),
            frame: CGRect(x: 1904, y: 63, width: 17, height: 892), enabled: false,
            settable: [AXAttribute.value]
        )))
        let bar = AXElement(handle: second, backend: fake)
        fake.reactions["set:\(AXAttribute.value)"] = {
            if fake.recordedSets.last?.handle == second && fake.recordedSets.last?.value == .double(1) {
                fake.mutate(second, attribute: AXAttribute.value, to: .double(0))
            }
        }
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.verifyTimeout = 0.04; actions.verifyInterval = 0.01
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("single-step selector must not run"); return nil }
        actions.visualScrollRounds = { _, _ in
            try bar.setAttribute(AXAttribute.value, to: .double(0))
            return (bar: bar, recheck: {})
        }
        #expect(throws: ActionError.self) {
            try actions.loadOlderMessages(reader: WeComReader(window: fake.rootElement), minRows: 3)
        }
        #expect(fake.recordedSets.last?.value == .double(1))
        #expect(try bar.value()?.doubleValue == 0)
    }

    @Test func uniqueBarUsesVisualFirstScrollAndAXRestore() throws {
        var tree = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        tree.children[0].children[33].children[6].children[0].children[0].children.removeLast()
        let fake = FakeAXBackend(root: tree)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let handle = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        let bar = AXElement(handle: handle, backend: fake)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.visualSelect = { _, _, _, _, _, _ in
            Issue.record("the command-owned visual round must choose the unique bar")
            return nil
        }
        var rounds = 0, rechecks = 0
        actions.visualScrollRounds = { _, value in
            rounds += 1
            #expect(value == 0)
            try bar.setAttribute(AXAttribute.value, to: .double(0))
            fake.replaceChildren(of: table, with: [Self.oldRow("older-a"), Self.oldRow("older-b")])
            return (bar: bar, recheck: {
                rechecks += 1
                #expect((try? bar.role()) == AXRole.scrollBar)
            })
        }
        let out = try actions.loadOlderMessages(reader: WeComReader(window: fake.rootElement), minRows: 2)
        #expect(rounds == 1 && rechecks >= 2)
        #expect(out.rowsBefore == 1 && out.rowsAfter == 2 && out.scrolls == 1 && out.restored)
        #expect(fake.recordedSets.map(\.value) == [.double(0), .double(1)])
        #expect(fake.recordedSets.allSatisfy { $0.handle == handle })
    }

    @Test func enoughVisibleRowsNeedNoVisualUploadOrScroll() throws {
        var tree = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        tree.children[0].children[33].children[6].children[0].children[0].children.removeLast()
        let fake = FakeAXBackend(root: tree)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("no visual upload expected"); return nil }
        actions.visualScrollRounds = { _, _ in
            Issue.record("no visual upload expected")
            throw ActionError.actionUnavailable("unexpected visual call")
        }
        let reader = try WeComReader(window: fake.rootElement)
        let visible = try reader.messages().count
        let out = try actions.loadOlderMessages(reader: reader, minRows: visible)
        #expect(out.scrolls == 0 && out.rowsBefore == visible && out.rowsAfter == visible)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func uniqueBarVisualFailureDoesNotFallBackToAXScroll() throws {
        var tree = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        tree.children[0].children[33].children[6].children[0].children[0].children.removeLast()
        let fake = FakeAXBackend(root: tree)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
        actions.visualSelect = { _, _, _, _, _, _ in Issue.record("one-step selector must not run"); return nil }
        var rounds = 0
        actions.visualScrollRounds = { _, _ in
            rounds += 1
            throw ActionError.actionUnavailable("synthetic model stop")
        }
        #expect(throws: ActionError.self) {
            try actions.loadOlderMessages(reader: WeComReader(window: fake.rootElement), minRows: 3)
        }
        #expect(rounds == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }
}
