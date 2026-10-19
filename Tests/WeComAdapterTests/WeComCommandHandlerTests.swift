import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// F3: minimal `ObjectStore` fake for `messageSendFile{ossKey}` handler tests — no network; `download` writes
/// a small `%PDF-`-signed body so `FileKind.rejection` accepts "a.pdf" (same signature convention as
/// `FileFetcherTests.pdf`).
final class FakeObjectStore: ObjectStore {
    var summary = "fake-oss"; var baseDir = "imctl"; var maxUploadBytes: Int64 = 10_000_000; var viewExpireSeconds = 60
    static let bytes = Data("%PDF-1.4 tiny".utf8)
    func exists(key: String) throws -> Bool { true }
    func put(fileURL: URL, key: String, contentType: String) throws {}
    func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL { URL(string: "https://b.example/\(key)")! }
    func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 { try Self.bytes.write(to: destination); return Int64(Self.bytes.count) }
    func delete(key: String) throws {}
}

@Suite("WeComCommandHandler on fake")
struct WeComCommandHandlerTests {
    let composerPath = [0, 33, 6, 0, 2, 0]
    let messageTablePath = [0, 33, 6, 0, 0, 0]

    func handler(_ fake: FakeAXBackend, allow extra: [String] = []) throws -> WeComCommandHandler {
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-handler-\(UUID().uuidString)"))
        let h = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: Set(["文件传输助手"] + extra), enabled: [.selectConversation, .composeText, .clearComposer, .scrollHistory, .submit, .navigate], phase: .phase1),
            checkpoints: cps, strategy: .enterKey, submitTimeout: 0.5
        )
        return h
    }

    @Test func listAndHistoryAndStatus() throws {
        let fake = try Fixtures.mainWindow()
        let h = try handler(fake)
        let list = try h.conversationList()
        #expect(list.count == 6 && list.contains { $0["title"] == "文件传输助手" && $0["selected"] == "true" })
        let hist = try h.messageHistory(limit: 10, scrollback: false)
        #expect(hist.isEmpty)   // the fixture's only row is a centered notice (B8), never a message row
        let status = try h.accountStatus()
        #expect(status["windowReachable"] == "true" && status["activeTitle"] == "文件传输助手" && status["conversationCount"] == "6")
        let description = try h.describe()
        #expect(description["submitStrategy"] == "enter")
        #expect(UInt64(description["visionCaptureCount"] ?? "") != nil)
        #expect(UInt64(description["visionRequestCount"] ?? "") != nil)
        #expect(UInt64(description["visionHTTP200Count"] ?? "") != nil)
    }

    /// Live 2026-09-15 fixture (5.0.11, redacted): one text message, two centered notices, one media row.
    @Test func historyCarriesKindAndOmitsTextForMediaRows() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-image-message.json")))
        let hist = try handler(fake).messageHistory(limit: 10, scrollback: false)
        #expect(hist.map { $0["kind"] } == ["message", "media"] && hist[0]["direction"] == "inbound" && hist[0]["timeLabel"] == "9:32")
        #expect(hist[1]["text"] == nil && hist[1]["direction"] == "unknown" && hist[1]["messageKey"] != nil)
    }

    @Test func fileTransferAssistantHistoryLabelsEvenLeftAndUnpositionedRowsAsOutbound() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: messageTablePath))
        fake.replaceChildren(of: table, with: [
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                    AXNode(role: AXRole.textArea, value: .string("self note"), frame: CGRect(x: 380, y: 160, width: 94, height: 15)),
                ]),
            ]),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 211, width: 1609, height: 246), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 211, width: 1609, height: 246)),
            ]),
        ])
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.messages().map(\.direction) == [.inbound, .unknown])
        let hist = try handler(fake).messageHistory(limit: 10, scrollback: false)
        #expect(hist.map { $0["kind"] } == ["message", "media"])
        #expect(hist.map { $0["direction"] } == ["outbound", "outbound"])
    }

    @Test func groupRenameGoesThroughThePolicyAndWritesTheHeader() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let title = try #require(try WeComReader(window: fake.rootElement).activeConversationTitle())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        let rowTitle = try #require(try WeComReader(window: fake.rootElement).activeConversationRow()?.handle.titleTextHandle(in: fake))
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string("新群名"))
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("新群名"))
        }
        let h = try handler(fake, allow: [title])
        h.policy.enabled.insert(.renameGroup)
        h.configureActions = { a in a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.groupOpenTimeout = 0.3 }
        let out = try h.groupRename(target: title, name: "新群名")
        #expect(out == ["title": "新群名", "renamed": "true", "requestedName": "新群名"])
        #expect(throws: ControlError.self) { try h.groupRename(target: "nobody", name: "x") }
    }

    @Test func historyWithScrollbackGoesThroughHandler() throws {
        let fake = try Fixtures.mainWindow()   // its only row is a notice: no message rows, so a positive limit always scrolls
        let h = try handler(fake)
        h.configureActions = { a in a.verifyTimeout = 0.05; a.verifyInterval = 0.01 }
        #expect(try h.messageHistory(limit: 5, scrollback: false).isEmpty)
        #expect(fake.recordedSets.last?.value == .double(1))   // normal reads move the client to newest
        let afterLatest = fake.recordedSets.count
        #expect(try h.messageHistory(limit: 0, scrollback: true).isEmpty)   // nothing asked for: no scrolling
        #expect(fake.recordedSets.count == afterLatest)
        #expect(try h.messageHistory(limit: 3, scrollback: true).isEmpty)   // scrolled (bars set), nothing more loaded
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.value && $0.value == .double(0) })
        #expect(fake.recordedSets.last?.value == .double(1))
    }

    @Test func ordinaryHistoryReadsNewestRowsAfterTheClientWasLeftInOldHistory() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: messageTablePath))
        let bar = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        fake.reactions["set:AXValue"] = {
            guard let last = fake.recordedSets.last, last.handle == bar, last.value == .double(1) else { return }
            fake.replaceChildren(of: table, with: [AXNode(role: AXRole.row, frame: CGRect(x: 311, y: 130, width: 1609, height: 60), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 130, width: 1609, height: 60), children: [
                    AXNode(role: AXRole.textArea, value: .string("newest"), frame: CGRect(x: 380, y: 140, width: 100, height: 20)),
                ]),
            ])])
        }
        let rows = try handler(fake).messageHistory(limit: 1, scrollback: false)
        #expect(rows.count == 1 && rows.first?["text"] == "newest")
        #expect(fake.recordedSets.contains { $0.handle == bar && $0.value == .double(1) })
    }

    @Test func ordinaryHistoryDoesNotRescrollAnAlreadyLatestPane() throws {
        let fake = try Fixtures.mainWindow()
        let bar = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        fake.mutate(bar, attribute: AXAttribute.value, to: .double(1))
        let rows = try handler(fake).messageHistory(limit: 30, scrollback: false)
        #expect(rows.isEmpty)  // this fixture only has a centered notice
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func sendCallsHooksAroundKeystrokeAndSucceeds() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: messageTablePath))
        let composer = try #require(fake.handle(atPath: composerPath))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var trace: [String] = []
        let h = try handler(fake)
        h.configureActions = { actions in
            actions.verifyTimeout = 0.3; actions.verifyInterval = 0.02
            actions.postReturnKey = { _, _ in
                trace.append("keystroke")
                var rows = existing.children
                rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                    AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                        AXNode(role: AXRole.textArea, value: .string("b1"), frame: CGRect(x: 1800, y: 160, width: 94, height: 15)),
                    ]),
                ]), at: rows.count - 1)
                fake.replaceChildren(of: table, with: rows)
                fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
            }
        }
        let result = try h.messageSend(target: "文件传输助手", text: "b1",
                                       checkpoint: { trace.append("checkpoint") }, afterSubmit: { trace.append("after") })
        #expect(result.state == .succeeded && result.evidence?.contains("outbound") == true)
        #expect(trace == ["checkpoint", "keystroke", "after"])
    }

    @Test func sendToNonAllowlistedTargetIsRefusedBeforeAnyAX() throws {
        let fake = try Fixtures.mainWindow()
        let h = try handler(fake)
        #expect(throws: ControlError.targetNotAllowed("张三")) {
            try h.messageSend(target: "张三", text: "x", checkpoint: {}, afterSubmit: {})
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func sendWhenAnotherConversationIsActiveSelectsFirstAndReportsMismatchOnFake() throws {
        let fake = try Fixtures.noComposer()
        let h = try handler(fake)
        h.configureActions = { a in a.verifyTimeout = 0.2; a.verifyInterval = 0.02 }
        #expect(throws: ControlError.self) {
            try h.messageSend(target: "文件传输助手", text: "x", checkpoint: {}, afterSubmit: {})
        }
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.selectedRows])
    }

    @Test func crashInjectionPropagates() throws {
        let fake = try Fixtures.mainWindow()
        let h = try handler(fake)
        h.configureActions = { a in a.verifyTimeout = 0.2; a.verifyInterval = 0.02; a.postReturnKey = { _, _ in } }
        #expect(throws: CrashInjected.self) {
            try h.messageSend(target: "文件传输助手", text: "x", checkpoint: {}, afterSubmit: { throw CrashInjected() })
        }
        #expect(try h.checkpoints.pending().count == 1)
    }


    @Test func sendFileRefusesDisallowedSourcesBeforeTouchingTheClientAndNeedsOSSForKeys() throws {
        let fake = try Fixtures.mainWindow()
        let h = try handler(fake)
        h.policy.enabled.insert(.sendFile)
        #expect(throws: ControlError.self) {
            try h.messageSendFile(target: "文件传输助手", source: .url(URL(string: "https://nope.example/a.pdf")!), fileName: nil, checkpoint: {}, afterSubmit: {})
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        do {
            _ = try h.messageSendFile(target: "文件传输助手", source: .ossKey("imctl/a.pdf"), fileName: nil, checkpoint: {}, afterSubmit: {})
            Issue.record("expected OSS_NOT_CONFIGURED")
        } catch let e as ControlError { #expect(e.code == "OSS_NOT_CONFIGURED") }
        #expect(WeComCommandHandler.sendFileTimeout(kind: "image", bytes: 1) == 15 && WeComCommandHandler.sendFileTimeout(kind: "file", bytes: 1) == 30)
        #expect(WeComCommandHandler.sendFileTimeout(kind: "video", bytes: 24_684_024) == 50 && WeComCommandHandler.sendFileTimeout(kind: "video", bytes: 300_000_000) == 180)
    }

    final class TraceBox { var events: [String] = [] }

    /// F3: handler over the group fixture, targeting the group itself (already the fixture's active
    /// conversation, so `messageSendFile` never has to call `selectConversation`) with `.sendFile` enabled.
    /// `postShortcut` / `postReturnKey` are the only client interaction the fake needs to script — the ossKey
    /// source (`FakeObjectStore`) means no network, and the injected pasteboard means no real `NSPasteboard`.
    func sendFileHandler(landPaste: Bool, trace: TraceBox) throws -> WeComCommandHandler {
        let fake = GroupFixture.backend()
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-handler-\(UUID().uuidString)"))
        let h = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.sendFile], phase: .phase1),
            checkpoints: cps, strategy: .enterKey, submitTimeout: 0.5
        )
        h.objectStore = FakeObjectStore()
        h.fileFetcher = FileFetcher(outbox: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-outbox-\(UUID().uuidString)"))
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        h.configureActions = { a in
            a.verifyTimeout = 0.3; a.verifyInterval = 0.02; a.pasteTimeout = 0.3
            a.frontmostPid = { 4242 }; a.restoreFrontmost = { _ in }   // the fake's own pid: nothing to bring to front or hand back
            a.pasteboard = RecordingPasteboard()   // from SendFileTests.swift; never touch the real NSPasteboard in a test
            a.postShortcut = { _, _ in
                trace.events.append("paste")
                if landPaste { fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("1")) }
            }
            a.postReturnKey = { _, _ in
                trace.events.append("return")
                fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("0"))
                var rows = GroupFixture.defaultMessages()
                let y: CGFloat = 454
                let cellChildren: [AXNode] = [
                    AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: y + 19, width: 42, height: 42)),
                    GroupFixture.text("a.pdf", x: 1657, y: y + 19, w: 100, h: 20), GroupFixture.text("3B", x: 1657, y: y + 45, w: 24),
                ]
                rows.append(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 82), children: [
                    AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 82), children: cellChildren),
                ]))
                fake.replaceChildren(of: table, with: rows + [AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: 1609, height: 931))])
            }
        }
        return h
    }

    /// F3: the success path binds `SubmitHooks` in paste → checkpoint → Return → afterSubmit order (checkpoint
    /// lands before the irreversible Return, matching `messageSend`'s contract), maps the paste-enter outcome
    /// to `SendFileResult`, and discards the outbox file whatever happens.
    @Test func sendFileSuccessPathBindsCheckpointBeforeReturnMapsTheResultAndDiscardsTheOutbox() throws {
        let trace = TraceBox()
        let h = try sendFileHandler(landPaste: true, trace: trace)
        let outbox = h.fileFetcher.outbox
        let result = try h.messageSendFile(
            target: GroupFixture.groupTitle, source: .ossKey("imctl/a.pdf"), fileName: nil,
            checkpoint: { trace.events.append("checkpoint") }, afterSubmit: { trace.events.append("afterSubmit") }
        )
        #expect(trace.events == ["paste", "checkpoint", "return", "afterSubmit"])
        #expect(result.state == .succeeded && result.kind == "file" && result.fileName == "a.pdf" && result.bytes == Int64(FakeObjectStore.bytes.count))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
    }

    /// F3: when the paste never lands, `messageSendFile` throws `PASTE_FAILED` before either hook runs — no
    /// checkpoint means nothing was recorded as possibly-sent — and the fetched file is still discarded.
    @Test func sendFileWhenThePasteNeverLandsThrowsPasteFailedBeforeAnyHookAndDiscardsTheOutbox() throws {
        let trace = TraceBox()
        let h = try sendFileHandler(landPaste: false, trace: trace)
        let outbox = h.fileFetcher.outbox
        do {
            _ = try h.messageSendFile(
                target: GroupFixture.groupTitle, source: .ossKey("imctl/a.pdf"), fileName: nil,
                checkpoint: { trace.events.append("checkpoint") }, afterSubmit: { trace.events.append("afterSubmit") }
            )
            Issue.record("expected PASTE_FAILED")
        } catch let e as ControlError { #expect(e.code == "PASTE_FAILED") }
        #expect(trace.events == ["paste"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
    }

    func groupHandler(policyFile: SendPolicy, identities: IdentityLookup = NoIdentities()) throws -> (WeComCommandHandler, FakeAXBackend) {
        let fake = GroupFixture.backend()
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-handler-\(UUID().uuidString)"))
        let h = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation, .composeText, .clearComposer, .scrollHistory, .submit, .navigate], phase: .phase1),
            checkpoints: cps, strategy: .enterKey, submitTimeout: 0.3, identities: identities
        )
        h.sendPolicyProvider = { policyFile }
        h.configureActions = { a in a.verifyTimeout = 0.2; a.verifyInterval = 0.02; a.postReturnKey = { _, _ in } }
        return (h, fake)
    }

    @Test func groupTargetsNeedAPolicyRuleAndChatIdTargetsNeedTheBridge() throws {
        var file = SendPolicy(); file.allow(.type(.group))
        let bridge = MapIdentities(items: [Identity(kind: .group, id: "wr1", title: "imctl测试群", updatedMs: 1)])
        let (h, fake) = try groupHandler(policyFile: file, identities: bridge)
        // the type rule lets the active group through; the fake never shows a bubble, so the send fails after composing (not a policy error)
        let r = try h.messageSend(target: "chatId:wr1", text: "hello", checkpoint: {}, afterSubmit: {})
        #expect(r.state != .succeeded && fake.recordedSets.contains { $0.attribute == AXAttribute.value })
        #expect(throws: ControlError.targetNotFound("chatId:wr2")) { try h.messageSend(target: "chatId:wr2", text: "x", checkpoint: {}, afterSubmit: {}) }
        // a customer is not covered by the group rule, and unknown-typed rows never are
        #expect(throws: ControlError.targetNotAllowed("小明·a1b2c3")) { try h.messageSend(target: "小明·a1b2c3", text: "x", checkpoint: {}, afterSubmit: {}) }
        #expect(throws: ControlError.targetNotAllowed("同事甲")) { try h.messageSend(target: "同事甲", text: "x", checkpoint: {}, afterSubmit: {}) }
        #expect(try h.describe()["policy"] == "titles=0 types=group chatIds=0 externalUserIds=0 requests=off/off")
        #expect(try h.describe()["targetSyntax"]?.contains("chatId:") == true)
    }

    @Test func readAndHistoryUseResolvedTargetsAndKeys() throws {
        var file = SendPolicy(); file.allow(.chatId("wr1"))
        let bridge = MapIdentities(items: [Identity(kind: .group, id: "wr1", title: "imctl测试群", updatedMs: 1)])
        let (h, _) = try groupHandler(policyFile: file, identities: bridge)
        let read = try h.conversationRead(target: "chatId:wr1")
        #expect(read["active"] == "imctl测试群" && read["messageCount"] == "4" && read["conversationType"] == "group" && read["chatId"] == "wr1")
        let hist = try h.messageHistory(limit: 10, scrollback: false)
        #expect(hist.count == 4 && hist[0]["sender"] == "张三" && hist[0]["messageKey"]?.count == 16 && hist.allSatisfy { $0["messageKey"] != nil })
        let status = try h.accountStatus()
        #expect(status["activeTitle"] == "imctl测试群" && status["activeType"] == "group" && status["activeMemberCount"] == "3")
        // B10: any listed conversation can be opened by default; the gate only comes back with policy.json.gateReads
        var gated = file; gated.gateReads = true
        h.sendPolicyProvider = { gated }
        #expect(throws: ControlError.targetNotAllowed("同事甲")) { try h.conversationRead(target: "同事甲") }
        h.sendPolicyProvider = { file }
        #expect(throws: ControlError.targetMismatch(expected: "同事甲", actual: "imctl测试群")) { try h.conversationRead(target: "同事甲") }   // the fixture cannot switch, but the policy let it try
        let list = try h.conversationList()
        #expect(list.contains { $0["title"] == "小明·a1b2c3" && $0["conversationType"] == "customer" && $0["markers"] == "微信" })
    }

    @Test func readCountsMessagesAndInfersTypeFromTheSameFreshParse() throws {
        let fake = GroupFixture.backend()
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        var tableChildrenReads = 0
        fake.onRead = { handle, attribute in
            if handle == table, attribute == AXAttribute.children { tableChildrenReads += 1 }
        }
        let result = try handler(fake, allow: [GroupFixture.groupTitle]).conversationRead(target: GroupFixture.groupTitle)
        #expect(result["active"] == GroupFixture.groupTitle && result["messageCount"] == "4" && result["conversationType"] == "group")
        // Layout discovery now stops at the table. The two reads come from
        // target resolution and the fresh count/type parse, not tree walking.
        #expect(tableChildrenReads == 2)
    }

    @Test func conversationReadReobservesAndRetriesOneDroppedSelection() throws {
        let fake = GroupFixture.backend()
        let h = try handler(fake, allow: ["同事甲"])
        h.configureActions = { a in a.verifyTimeout = 0.02; a.verifyInterval = 0.005 }
        let title = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var selections = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            selections += 1
            if selections == 2 {
                fake.mutate(title.handle, attribute: AXAttribute.value, to: .string("同事甲"))
            }
        }
        let result = try h.conversationRead(target: "同事甲")
        #expect(result["active"] == "同事甲")
        #expect(selections == 2)
    }

    @Test func conversationReadStopsAfterTwoUnverifiedSelections() throws {
        let fake = GroupFixture.backend()
        let h = try handler(fake, allow: ["同事甲"])
        h.configureActions = { a in a.verifyTimeout = 0.02; a.verifyInterval = 0.005 }
        #expect(throws: ControlError.targetMismatch(expected: "同事甲", actual: GroupFixture.groupTitle)) {
            try h.conversationRead(target: "同事甲")
        }
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 2)
    }

    @Test func clientNavigateGoesThroughTheHandlerAndMapsMissingMenusToUnsupported() throws {
        let fake = try NavigateFixture.app()
        let h = try handler(fake)
        h.configureActions = { a in a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil } }
        let out = try h.clientNavigate(action: .previousConversation)
        #expect(out["action"] == "previousConversation" && out["changed"] == "false" && out["before"] == "文件传输助手")
        #expect(out["enabled"] == "false")
        #expect(fake.recordedActions.isEmpty)
        let bare = try Fixtures.mainWindow()   // window root: no menu bar reachable
        #expect(throws: ControlError.unsupported("action menu 窗口 › 选择下一个会话 unavailable")) {
            try handler(bare).clientNavigate(action: .nextConversation)
        }
    }

    /// B14: handler over the group fixture with a dormant picker node that becomes
    /// an 添加群成员 sheet only after this command presses a header button, driven end to
    /// end — resolve → policy → action → checkpoint/确定/afterSubmit — the way `sendFileHandler` above
    /// drives `messageSendFile`. `postReturnKey` grows the sheet's selected table; pressing 确定 closes
    /// the sheet and, when a side-panel heading was given, grows its `群成员·N` count by one — the
    /// evidence `addGroupMembers` looks for. A `nil` heading leaves the fixture with no member count at
    /// all (the NOT_A_GROUP path never touches the sheet, so nothing needs scripting there).
    func addMembersHandler(memberCountHeading: String? = "群成员·3", trace: TraceBox) throws -> WeComCommandHandler {
        let sheetNode = try AddGroupMembersTests.addMembersSheetNode()
        // The heading sits in the side panel, right of the chat pane that ends at x 1690.
        let fake = FakeAXBackend(root: GroupFixture.window(headerTitle: GroupFixture.groupTitle, addMemberButtons: true, sheet: sheetNode,
                                                           memberPanelMinX: 1690))
        let splitGroup = try #require(fake.handle(atPath: [0]))
        let countHandle = memberCountHeading.flatMap { fake.appendChild(to: splitGroup, node: GroupFixture.text($0, x: 1700, y: 120, w: 90)) }
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-handler-\(UUID().uuidString)"))
        let h = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation, .addGroupMembers], phase: .phase1),
            checkpoints: cps, strategy: .enterKey, submitTimeout: 0.5
        )
        guard let sheet = try GroupPickerSheet.locate(window: fake.rootElement) else { return h }
        let outline = sheet.outline.handle
        let selected = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let cancel = sheet.cancelButton?.handle
        let sheetHandle = sheet.sheet.handle
        let rowByName = ["李四": try GroupPickerTests.addMembersRowNode(named: "李四"), "王五": try GroupPickerTests.addMembersRowNode(named: "王五")]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: outline, with: [row])
            }
        }
        var returns = 0
        h.configureActions = { a in
            a.verifyTimeout = 0.2; a.verifyInterval = 0.01; a.addMembersTimeout = 0.05; a.groupOpenTimeout = 0.3
            a.frontmostPid = { 4242 }; a.restoreFrontmost = { _ in }; a.postShortcut = { _, _ in }
            a.postReturnKey = { _, _ in
                returns += 1
                fake.appendChild(to: selected, node: GroupPickerTests.selectedRowNode(
                    named: (try? sheet.searchField?.valueString()) ?? "",
                    y: 388 + 36 * CGFloat(returns)))
                fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
            }
        }
        fake.reactions["action:\(AXAction.press)"] = {
            guard let pressed = fake.recordedActions.last?.handle else { return }
            if pressed == done {
                trace.events.append("confirm")
                fake.mutate(sheetHandle, attribute: AXAttribute.role, to: .string(AXRole.group))
                if let countHandle { fake.mutate(countHandle, attribute: AXAttribute.value, to: .string("群成员·4")) }
            } else if pressed == cancel {
                trace.events.append("cancel")
                fake.mutate(sheetHandle, attribute: AXAttribute.role, to: .string(AXRole.group))
            } else {
                // The command, rather than a previous user operation, opens this sheet.
                fake.mutate(sheetHandle, attribute: AXAttribute.role, to: .string(AXRole.sheet))
            }
        }
        fake.mutate(sheetHandle, attribute: AXAttribute.role, to: .string(AXRole.group))
        return h
    }

    /// B14: the handler resolves the (already active) group, gates through the policy, then runs the
    /// same checkpoint → 确定 → afterSubmit order `messageSend` / `messageSendFile` use — the checkpoint
    /// hook fires before the irreversible press, never after.
    @Test func groupAddMembersOrdersCheckpointConfirmAfterSubmitAndMapsTheResult() throws {
        let trace = TraceBox()
        let h = try addMembersHandler(trace: trace)
        let out = try h.groupAddMembers(target: GroupFixture.groupTitle, members: ["李四", "王五"], dryRun: false,
                                        checkpoint: { trace.events.append("checkpoint") }, afterSubmit: { trace.events.append("afterSubmit") })
        #expect(out.state == .succeeded && out.before == 3 && out.after == 4 && out.evidence == "count 3→4")
        #expect(out.added == ["王五"] && out.skipped.map(\.reason) == ["alreadyMember"])
        #expect(trace.events == ["checkpoint", "confirm", "afterSubmit"])
    }

    /// B14: no header suffix and no `群成员·N` panel means this conversation has no member list — the
    /// handler maps `ActionError.notAGroup` to `ControlError.notAGroup` without ever touching the sheet.
    @Test func groupAddMembersMapsNotAGroupWhenTheFixtureHasNoMemberCount() throws {
        let trace = TraceBox()
        let h = try addMembersHandler(memberCountHeading: nil, trace: trace)
        #expect(throws: ControlError.notAGroup(GroupFixture.groupTitle)) {
            try h.groupAddMembers(target: GroupFixture.groupTitle, members: ["王五"], dryRun: false, checkpoint: {}, afterSubmit: {})
        }
        #expect(trace.events.isEmpty)
    }

    /// B14 Task 6 fix: `.addGroupMembers` must be checked immediately after resolving, before any
    /// conversation switch — a target this policy refuses must never cause the client to select it
    /// first. `enabled` deliberately leaves `.addGroupMembers` out so the failure is unambiguous.
    /// Reuses `noComposer` / "文件传输助手" from `sendWhenAnotherConversationIsActiveSelectsFirstAndReportsMismatchOnFake`
    /// above, which already proves this fixture's active conversation differs from that title, so a
    /// handler that still selected before checking policy would go ahead and set `AXSelectedRows`
    /// (then time out verifying the switch, same as that `messageSend` case) before ever reaching
    /// the policy error; a short `verifyTimeout` keeps that old-order failure mode fast, not just
    /// eventually-correct.
    @Test func groupAddMembersChecksPolicyBeforeSelectingWhenNotEnabled() throws {
        let fake = try Fixtures.noComposer()
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-handler-\(UUID().uuidString)"))
        let h = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation], phase: .phase1),
            checkpoints: cps, strategy: .enterKey, submitTimeout: 0.5
        )
        h.configureActions = { a in a.verifyTimeout = 0.05; a.verifyInterval = 0.01 }
        #expect(throws: ControlError.internalError("action addGroupMembers not enabled by policy")) {
            try h.groupAddMembers(target: "文件传输助手", members: ["王五"], dryRun: false, checkpoint: {}, afterSubmit: {})
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }
}
