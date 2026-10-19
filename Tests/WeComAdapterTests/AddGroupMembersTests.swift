import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// B14 `group.addMembers` on the synthetic group window: the header button that opens 添加群成员,
/// the member picking (already-in-the-group rows skipped), the checkpoint that must be on disk
/// before the irreversible 确定, and the evidence verdicts (member count / a NEW 邀请 row / nothing).
/// Names are the fixture's neutral 李四 / 王五 / 赵六; nothing here talks to a real client.
@Suite("WeComActions.addGroupMembers on the group fixture")
struct AddGroupMembersTests {
    static let target = ResolvedTarget(title: GroupFixture.groupTitle, type: .group)

    /// What the flow did, in order: `checkpoint` (a pending checkpoint hit the store), `before` /
    /// `after` (the executor hooks), `confirm` / `cancel` / `header` (which button was pressed).
    final class Journal {
        var events: [String] = []
        var returns = 0
    }

    final class RecordingCheckpoints: CheckpointStore {
        let journal: Journal
        private(set) var written: [SubmitCheckpoint] = []
        init(journal: Journal) { self.journal = journal }
        func write(_ checkpoint: SubmitCheckpoint) throws {
            written.append(checkpoint)
            journal.events.append(checkpoint.state == .pending ? "checkpoint" : "checkpoint(\(checkpoint.state.rawValue))")
        }
        func load(id: String) throws -> SubmitCheckpoint? { written.last { $0.id == id } }
        func pending() throws -> [SubmitCheckpoint] { written.filter { $0.state == .pending } }
    }

    /// How the fake client reacts to 确定.
    enum Confirm {
        case closesAndGrowsTheCount, closesOnly, closesAndWritesTheInvitationRow, staysOpen
        /// Writes an invitation naming only ONE of the two members the call added.
        case closesAndWritesAPartialInvitationRow
        /// Closes only on the Nth poll of the post-确定 close wait, and leaves no other trace: adding
        /// members is a server round trip, so the sheet does not go away on the next repaint.
        case closesOnTheNthPollAndNothingElse(Int)
    }

    /// What a header-button press hangs off the window — the client opening a sheet.
    enum Opens {
        /// The recorded 添加群成员 sheet.
        case addMembers
        /// The same sheet, except its 添加群成员 title only turns up one poll later: the right-hand
        /// pane that carries it lags the outline, so for a beat the real sheet cannot name itself.
        case addMembersWithALateTitle
        /// A sheet of the same family under another title (a 发起群聊): not ours, cancel it.
        case anotherSheet
    }

    /// Everything the fake needs to script ONE sheet, plus what a Return does to it. A class because
    /// the sheet may only appear later: a header press rewires this in place while the `WeComActions`
    /// value the test already holds keeps calling through it.
    final class SheetBox {
        var sheet: AXElementHandle?
        var outline: AXElementHandle?
        var done: AXElementHandle?
        var cancel: AXElementHandle?
        var onReturn: (() -> Void)?
    }

    struct Harness {
        let fake: FakeAXBackend
        let window: AXElement
        let reader: WeComReader
        let checkpoints: RecordingCheckpoints
        let journal: Journal
        let actions: WeComActions
        /// Tears the sheet down the way 确定 / 取消 do, for tests that must close it themselves.
        let closeSheet: () -> Void
        /// The side panel's `群成员·N` heading, for tests that make it unreadable mid-poll.
        let countHandle: AXElementHandle?
    }

    /// The 添加群成员 sheet as the client hangs it off the window (Task 3's synthetic fixture).
    static func addMembersSheetNode() throws -> AXNode {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json"))
        return try #require(root.children.first { $0.role == AXRole.sheet })
    }

    /// The recorded sheet ships exactly two selectable rows — 李四, whom the client marks as already
    /// in the group, and 王五 — so a call that must add TWO people borrows 王五's row under a second
    /// neutral name. Nothing but the name text changes.
    static func renaming(_ node: AXNode, _ from: String, to: String) -> AXNode {
        var copy = node
        if copy.value == .string(from) { copy.value = .string(to) }
        copy.children = copy.children.map { renaming($0, from, to: to) }
        return copy
    }

    /// Drops every node carrying `text`, so the sheet can be handed that text back a poll later.
    static func dropping(_ node: AXNode, text: String) -> AXNode {
        var copy = node
        copy.children = copy.children.filter { $0.value != .string(text) }.map { dropping($0, text: text) }
        return copy
    }

    /// The sheet's own title, and where the recording puts it: x 985 in the right-hand pane, past the
    /// outline's right edge (963) — which is the only thing telling 添加群成员 and 发起群聊 apart.
    static let sheetTitle = "添加群成员"
    static var titleNode: AXNode { GroupFixture.text(sheetTitle, x: 985, y: 351, w: 271, h: 24) }

    /// The recorded sheet, adapted to what this press is supposed to open.
    static func sheetNode(_ opens: Opens) throws -> AXNode {
        let node = try addMembersSheetNode()
        switch opens {
        case .addMembers: return node
        case .addMembersWithALateTitle: return dropping(node, text: sheetTitle)
        case .anotherSheet: return renaming(node, sheetTitle, to: "发起群聊")
        }
    }

    /// A group window with the 2026-09-23 header buttons, the side panel's `群成员·N` heading and —
    /// with `withSheet` — a sheet already open (`initialSheet` says which). Scripted client behaviour
    /// matches the createGroup tests: typing filters the outline to one row, a Return lists it on the
    /// right and enables 确定, 确定 / 取消 tear the sheet down (the role stops being `AXSheet`, which is
    /// all `GroupPickerSheet.locate` looks at).
    ///
    /// The knobs past `memberCountHeading` each pin one review finding: `labelledHeaderButtons` puts
    /// labelled controls in the header band, `staleInvitationRow` gives the group a 邀请 row from an
    /// earlier add, `preSelected` leaves the open sheet with somebody already chosen,
    /// `confirmStaysDisabled` keeps 确定 disabled however many members are picked, `decoyBanner`
    /// adds the header banner an external group carries under its title (2026-09-15, 5.0.11) with a
    /// member count written into it — it sits in the header band, nowhere near the side panel, and
    /// the client lays it out BEFORE the panel, so an unscoped scan reads it first — and
    /// `opensOnPress` is what the client hangs off the window on each header press in turn, which is
    /// how the real flow gets its sheet (the previous fixture could only start with one already up).
    /// `cancelIsIneffective` makes every 取消 press in this run a no-op — the sheet stays attached
    /// exactly as `AXRole.sheet` — so a test can prove the loop waits for the sheet to actually go
    /// away instead of trusting a press that may not have been obeyed.
    /// `verifyTimeout` / `addMembersTimeout` are injected so a test can make one budget run out while
    /// the other has not, without the suite ever waiting a production second.
    func harness(withSheet: Bool, confirm: Confirm = .closesAndGrowsTheCount,
                 enabled: Set<ActionKind> = [.addGroupMembers], phase: ActionPolicy.Phase = .phase1,
                 memberCountHeading: String? = "群成员·3", labelledHeaderButtons: Bool = false,
                 staleInvitationRow: String? = nil, preSelected: Int = 0,
                 confirmStaysDisabled: Bool = false, decoyBanner: Bool = false,
                 selectedIdentityOverride: String? = nil,
                 initialSheet: Opens = .addMembers, opensOnPress: [Opens] = [.addMembers],
                 cancelIsIneffective: Bool = false, memberPanelMinX: CGFloat = 1690, memberCountX: CGFloat = 1700,
                 verifyTimeout: TimeInterval = 0.2, addMembersTimeout: TimeInterval = 0.05) throws -> Harness {
        let sheetNode = withSheet ? try Self.sheetNode(initialSheet) : nil
        // This group's header carries no "(N)" suffix (live 2026-09-23) — the count lives in the side panel.
        let fake = FakeAXBackend(root: GroupFixture.window(headerTitle: GroupFixture.groupTitle, addMemberButtons: true,
                                                           labelledHeaderButtons: labelledHeaderButtons, sheet: sheetNode,
                                                           memberPanelMinX: memberPanelMinX))
        let window = fake.rootElement
        let splitGroup = try #require(fake.handle(atPath: [0]))
        // Under the title, left of the panel, and laid out first — whatever it says is not the count.
        if decoyBanner { fake.appendChild(to: splitGroup, node: GroupFixture.text("由企业微信用户创建的外部群聊 · 群成员·99人", x: 326, y: 44, w: 300, h: 16)) }
        // x 1700 of this 1920-wide window by default: in the side panel, right of the chat pane that ends at 1690.
        let countHandle = memberCountHeading.flatMap { fake.appendChild(to: splitGroup, node: GroupFixture.text($0, x: memberCountX, y: 120, w: 90)) }
        let messageTable = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        // History this group already carried before the call.
        if let staleInvitationRow { fake.appendChild(to: messageTable, node: GroupFixture.systemRow(y: 454, text: staleInvitationRow)) }
        let reader = try WeComReader(window: window)
        let journal = Journal()
        let checkpoints = RecordingCheckpoints(journal: journal)
        let box = SheetBox()
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: enabled, phase: phase),
                             verifyTimeout: verifyTimeout, verifyInterval: 0.01)
        a.addMembersTimeout = addMembersTimeout
        a.groupOpenTimeout = 0.3
        a.frontmostPid = { 4242 }          // the fake's own pid: nothing to bring to front or hand back
        a.restoreFrontmost = { _ in }
        a.postShortcut = { _, _ in }
        a.postReturnKey = { _, _ in journal.returns += 1; box.onReturn?() }

        let close: (AXElementHandle?) -> Void = { handle in
            guard let handle else { return }
            fake.mutate(handle, attribute: AXAttribute.role, to: .string(AXRole.group))
        }
        /// Runs `body` on the Nth `GroupPickerSheet.locate` from now: one window-children read each,
        /// which is how a test says "the client only reacted a few polls into the wait".
        var polls = 0
        let onLocate: (Int, @escaping () -> Void) -> Void = { nth, body in
            polls = 0
            fake.onRead = { handle, name in
                guard name == AXAttribute.children, handle == fake.rootHandle else { return }
                polls += 1
                if polls >= nth { fake.onRead = nil; body() }
            }
        }
        let wangwu = try GroupPickerTests.addMembersRowNode(named: "王五")
        let rowByName = ["李四": try GroupPickerTests.addMembersRowNode(named: "李四"), "王五": wangwu,
                         "赵六": Self.renaming(wangwu, "王五", to: "赵六")]
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard let outline = box.outline else { return }
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: outline, with: [row])
            }
        }
        // Scripts one sheet — the one that is open now. `preSelected` rows are a sheet somebody else
        // left half-filled: already in the chosen list on the right.
        let wire: (GroupPickerSheet, Int) -> Void = { sheet, preSelected in
            box.sheet = sheet.sheet.handle
            box.outline = sheet.outline.handle
            box.done = sheet.doneButton?.handle
            box.cancel = sheet.cancelButton?.handle
            guard let selected = sheet.selectedTable?.handle, let done = box.done else { return }
            let row: (Int) -> AXNode = { AXNode(role: AXRole.row, frame: CGRect(x: 961, y: 388 + 36 * CGFloat($0), width: 319, height: 36)) }
            for i in 0..<preSelected { fake.appendChild(to: selected, node: row(i + 1)) }
            box.onReturn = {
                fake.appendChild(to: selected, node: GroupPickerTests.selectedRowNode(
                    named: selectedIdentityOverride ?? ((try? sheet.searchField?.valueString()) ?? ""),
                    y: 388 + 36 * CGFloat(preSelected + journal.returns)))
                fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(!confirmStaysDisabled))
            }
        }
        var queue = opensOnPress
        fake.reactions["action:\(AXAction.press)"] = {
            guard let pressed = fake.recordedActions.last?.handle else { return }
            if pressed == box.done {
                journal.events.append("confirm")
                switch confirm {
                case .staysOpen: break
                case .closesOnly: close(box.sheet)
                case .closesAndGrowsTheCount:
                    close(box.sheet)
                    if let countHandle { fake.mutate(countHandle, attribute: AXAttribute.value, to: .string("群成员·4")) }
                case .closesAndWritesTheInvitationRow, .closesAndWritesAPartialInvitationRow:
                    close(box.sheet)
                    fake.appendChild(to: messageTable, node: GroupFixture.systemRow(y: 494, text: "你邀请王五加入了外部群聊"))
                case .closesOnTheNthPollAndNothingElse(let nth):
                    let sheetHandle = box.sheet
                    onLocate(nth) { close(sheetHandle) }
                }
            } else if pressed == box.cancel {
                journal.events.append("cancel")
                if !cancelIsIneffective { close(box.sheet) }
            } else {
                journal.events.append("header")
                guard !queue.isEmpty else { return }
                let opens = queue.removeFirst()
                guard let node = try? Self.sheetNode(opens), let handle = fake.appendChild(to: fake.rootHandle, node: node),
                      let opened = try? GroupPickerSheet.locate(window: window) else { return }
                wire(opened, 0)
                // The pane carrying the title is a beat behind the outline: hand it over one poll in.
                if case .addMembersWithALateTitle = opens { onLocate(2) { fake.appendChild(to: handle, node: Self.titleNode) } }
            }
        }
        if withSheet, let sheet = try GroupPickerSheet.locate(window: window) { wire(sheet, preSelected) }
        return Harness(fake: fake, window: window, reader: reader, checkpoints: checkpoints, journal: journal,
                       actions: a, closeSheet: { close(box.sheet) }, countHandle: countHandle)
    }

    func add(_ h: Harness, _ members: [String], dryRun: Bool = false, hooks: SubmitHooks = SubmitHooks()) throws -> AddMembersOutcome {
        try h.actions.addGroupMembers(members, target: Self.target, dryRun: dryRun, app: h.window, window: h.window,
                                      reader: h.reader, checkpoints: h.checkpoints, hooks: hooks)
    }

    /// minX of every element the fake was asked to press, in order.
    static func pressedXs(_ fake: FakeAXBackend) -> [CGFloat] {
        fake.recordedActions.filter { $0.action == AXAction.press }
            .compactMap { (try? AXElement(handle: $0.handle, backend: fake).frame())??.minX }
    }

    /// (1) Live 2026-09-23 (5.0.11): the header's two untitled buttons are the only AX way into the
    /// sheet, and the recording showed the RIGHTMOST one (x 1879) opening it — hence right to left.
    @Test func headerButtonsAreTheTitlesSiblingsOrderedRightToLeft() throws {
        let h = try harness(withSheet: false)
        let xs = try WeComActions.headerButtons(layout: h.reader.layout).map { try $0.frame()?.minX ?? -1 }
        #expect(xs == [1879, 1839])
        // Any other conversation's header has none of them, and nothing is pressed blindly.
        let plain = FakeAXBackend(root: GroupFixture.window())
        #expect(try WeComActions.headerButtons(layout: WeComReader(window: plain.rootElement).layout).isEmpty)
    }

    /// (2) Both header buttons are tried (the second one's purpose is unknown, so whatever it opens
    /// is cancelled), and a client that shows no sheet at all is `ACTION_UNAVAILABLE` — never a
    /// half-finished add.
    @Test func noSheetAfterPressingBothHeaderButtonsIsActionUnavailable() throws {
        let h = try harness(withSheet: false, opensOnPress: [])
        #expect(throws: ActionError.actionUnavailable("添加群成员")) { try add(h, ["王五"]) }
        let rightmost = try #require(try WeComActions.headerButtons(layout: h.reader.layout).first)
        let presses = h.fake.recordedActions.filter { $0.action == AXAction.press }
        #expect(presses.count == 2)
        #expect(presses.first?.handle == rightmost.handle)
        #expect(presses.filter { $0.handle == rightmost.handle }.count == 1)
        #expect(h.checkpoints.written.isEmpty && h.journal.returns == 0)
    }

    /// (3) dryRun walks the whole selection — 李四 is already in the group and is skipped without a
    /// Return, 王五 is selected — and then presses 取消: no checkpoint, no 确定, nothing added.
    @Test func dryRunSelectsThenCancelsAndNeverPressesConfirm() throws {
        let h = try harness(withSheet: false)
        let out = try add(h, ["李四", "王五"], dryRun: true)
        #expect(out.state == .succeeded && out.evidence == "dry-run")
        #expect(out.added == ["王五"] && out.before == 3 && out.after == nil)
        #expect(out.skipped.count == 1 && out.skipped[0].name == "李四" && out.skipped[0].reason == "alreadyMember")
        #expect(h.journal.returns == 1)                     // 李四 never got one
        #expect(h.journal.events == ["header", "cancel"])   // no checkpoint, no 确定
        #expect(h.checkpoints.written.isEmpty)
    }

    /// A count increment after Return is insufficient: the client may have
    /// selected a different row. This must cancel before the checkpoint/确定.
    @Test func differentSelectedMemberFailsClosedBeforeConfirm() throws {
        let h = try harness(withSheet: false, selectedIdentityOverride: "赵六")
        #expect(throws: ActionError.verifyFailed("Return on the search field did not select the requested member")) {
            try add(h, ["王五"])
        }
        #expect(h.journal.returns == 1)
        #expect(h.journal.events == ["header"])
        #expect(h.checkpoints.written.isEmpty)
    }

    @Test func selectedRowWithoutAXIdentityFailsClosedBeforeConfirm() throws {
        let h = try harness(withSheet: false, selectedIdentityOverride: "")
        #expect(throws: ActionError.verifyFailed("Return on the search field did not select the requested member")) {
            try add(h, ["王五"])
        }
        #expect(h.journal.returns == 1)
        #expect(h.journal.events == ["header"])
        #expect(h.checkpoints.written.isEmpty)
    }

    /// (4) The irreversible step: the checkpoint is on disk BEFORE 确定 is pressed (crash in between
    /// ⇒ `unknown`, never a re-run), the hooks bracket the press, and the side panel's count growing
    /// by exactly the number added is the evidence.
    @Test func confirmWritesTheCheckpointFirstAndTheGrownMemberCountIsEvidence() throws {
        let h = try harness(withSheet: false, confirm: .closesAndGrowsTheCount)
        let hooks = SubmitHooks(beforeIrreversible: { h.journal.events.append("before") },
                                afterIrreversible: { h.journal.events.append("after") })
        let out = try add(h, ["李四", "王五"], hooks: hooks)
        #expect(out.state == .succeeded && out.before == 3 && out.after == 4 && out.evidence == "count 3→4")
        #expect(out.added == ["王五"] && out.skipped.map(\.reason) == ["alreadyMember"])
        #expect(Array(h.journal.events.prefix(5)) == ["header", "checkpoint", "before", "confirm", "after"])
        #expect(h.journal.events.filter { $0 == "checkpoint" || $0 == "confirm" } == ["checkpoint", "confirm"])
        #expect(h.checkpoints.written.first?.state == .pending && h.checkpoints.written.first?.text == "王五")
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .succeeded)
    }

    /// (5) 确定 pressed, sheet closed, but the count never moved and the client wrote no 邀请 row:
    /// `unknown` — the add may or may not have happened, and nothing retries it.
    @Test func aConfirmedSheetThatLeavesNoTraceIsUnknown() throws {
        let h = try harness(withSheet: false, confirm: .closesOnly)
        let out = try add(h, ["王五"])
        #expect(out.state == .unknown && out.evidence == "no-evidence" && out.before == 3 && out.after == 3)
        #expect(h.journal.events.contains("confirm"))
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .unknown)
    }

    /// (6) The policy decides before any AX call: a build without `.addGroupMembers` enabled and the
    /// phase-0 build (where the sheet's 确定 is as irreversible as `submit`) touch nothing.
    @Test func policyIsCheckedBeforeAnythingIsPressed() throws {
        let denied = try harness(withSheet: true, enabled: [])
        #expect(throws: PolicyError.notEnabled(.addGroupMembers)) { try add(denied, ["王五"]) }
        let phase0 = try harness(withSheet: true, phase: .phase0)
        #expect(throws: PolicyError.phaseForbids(.addGroupMembers)) { try add(phase0, ["王五"]) }
        #expect(denied.fake.recordedActions.isEmpty && denied.fake.recordedSets.isEmpty)
        #expect(phase0.fake.recordedActions.isEmpty && phase0.fake.recordedSets.isEmpty)
        #expect(denied.checkpoints.written.isEmpty && phase0.checkpoints.written.isEmpty)
    }

    /// (7) `NOT_A_GROUP`: no "(N)" in the header and no `群成员·N` panel means this conversation has
    /// no member list, so the sheet is never opened.
    @Test func aConversationWithoutAMemberCountIsNotAGroup() throws {
        let h = try harness(withSheet: true, memberCountHeading: nil)
        #expect(throws: ActionError.notAGroup(GroupFixture.groupTitle)) { try add(h, ["王五"]) }
        #expect(h.fake.recordedActions.isEmpty && h.checkpoints.written.isEmpty)
    }

    /// (8) The other evidence the client offers (live 2026-09-23): the system row "你邀请…加入了外部群聊",
    /// written by the client AFTER 确定. It counts only when it names every member this call added.
    @Test func theInvitationRowIsEvidenceWhenTheCountDoesNotMove() throws {
        let h = try harness(withSheet: false, confirm: .closesAndWritesTheInvitationRow)
        let out = try add(h, ["王五"])
        #expect(out.state == .succeeded && out.after == 3)
        #expect(out.evidence.hasPrefix("row #") && out.evidence.hasSuffix("邀请"))
    }

    /// (9) Finding 1 — the 邀请 evidence needs a row that was NOT on screen before 确定. This group's
    /// history already holds an invitation naming 王五 (an earlier add, since undone); 确定 is
    /// pressed, the count does not move and the client writes nothing new, so the honest verdict is
    /// `unknown`. Without the baseline the stale row would have vouched for a press that did nothing.
    @Test func aStaleInvitationRowFromAnEarlierAddIsNotEvidence() throws {
        let h = try harness(withSheet: false, confirm: .closesOnly, staleInvitationRow: "你邀请王五加入了外部群聊")
        let out = try add(h, ["王五"])
        #expect(out.state == .unknown && out.evidence == "no-evidence")
        #expect(h.journal.events.contains("confirm"))
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .unknown)
    }

    /// (10) Finding 2 — the header band may hold labelled controls too (a 群设置 button, an icon with
    /// an `AXDescription`). Only the untitled, description-less pair is the way into 添加群成员, so a
    /// labelled button is never listed and never pressed, even when it sorts rightmost (x 1890).
    @Test func labelledButtonsInTheHeaderBandAreNeitherListedNorPressed() throws {
        let h = try harness(withSheet: false, labelledHeaderButtons: true, opensOnPress: [])
        let xs = try WeComActions.headerButtons(layout: h.reader.layout).map { try $0.frame()?.minX ?? -1 }
        #expect(xs == [1879, 1839])
        #expect(throws: ActionError.actionUnavailable("添加群成员")) { try add(h, ["王五"]) }
        #expect(Self.pressedXs(h.fake) == [1879, 1839])
    }

    /// (11) Finding 3 — `AXPress` on 确定 can throw `kAXErrorCannotComplete`: the client did not
    /// answer in time, but the press may well have been dispatched. The executor turns a THROW into
    /// `failed`, so rethrowing would report "nothing was added" about an add that may have gone
    /// through. The press is treated as made and the usual closed / evidence logic decides: the sheet
    /// is gone with nothing to show for it ⇒ `unknown` / `confirm-threw`, and the checkpoint is never
    /// marked `failed`.
    @Test func aThrowingConfirmPressOnASheetThatClosesIsUnknownNotFailed() throws {
        let h = try harness(withSheet: false, confirm: .closesOnly)
        // Armed in the last hook before the press: the client takes it and answers nothing. The
        // sheet must still be present at the new pre-press gate; it closes in the after hook.
        let hooks = SubmitHooks(beforeIrreversible: {
            h.fake.injectedFailures["action:\(AXAction.press)"] = .cannotComplete("AXPress 确定")
        }, afterIrreversible: {
            h.closeSheet()
            h.fake.injectedFailures["action:\(AXAction.press)"] = nil
        })
        let out = try add(h, ["王五"], hooks: hooks)
        #expect(out.state == .unknown && out.evidence == "confirm-threw")
        #expect(out.details["closed"] == "true" && out.details["confirmThrew"] == "true")
        #expect(out.added == ["王五"])
        #expect(!h.checkpoints.written.contains { $0.state == .failed })
        #expect(h.checkpoints.written.first?.state == .pending)
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .unknown)
    }

    /// A sheet present before the command is never adopted or cancelled, even when it belongs to
    /// the same widget family. The selected person may have been chosen by the user.
    @Test func anAlreadyOpenSheetCarryingASelectionIsLeftIntact() throws {
        let h = try harness(withSheet: true, preSelected: 1)
        #expect(throws: ActionError.actionUnavailable("添加群成员：已有弹窗")) { try add(h, ["王五"]) }
        #expect(h.journal.events.isEmpty)
        #expect(try GroupPickerSheet.locate(window: h.window) != nil)
        #expect(h.checkpoints.written.isEmpty && h.journal.returns == 0)
    }

    @Test func anAlreadyOpenEmptySheetIsAlsoLeftIntact() throws {
        let h = try harness(withSheet: true)
        let before = try #require(try GroupPickerSheet.locate(window: h.window))
        #expect(throws: ActionError.actionUnavailable("添加群成员：已有弹窗")) { try add(h, ["王五"], dryRun: true) }
        #expect(try GroupPickerSheet.locate(window: h.window)?.sheet.handle == before.sheet.handle)
        #expect(h.journal.events.isEmpty && h.checkpoints.written.isEmpty)
    }

    @Test func commitGateRunsAfterSelectionBeforeCheckpointAndBeforeConfirm() throws {
        for deniedAt in 1...4 {
            let h = try harness(withSheet: false)
            var action = h.actions
            var gateCalls = 0
            action.addMembersCommitGate = {
                gateCalls += 1
                if gateCalls == deniedAt { throw ControlError.paused([.api]) }
            }
            #expect(throws: ControlError.self) {
                try action.addGroupMembers(["王五"], target: Self.target, dryRun: false,
                                           app: h.window, window: h.window, reader: h.reader,
                                           checkpoints: h.checkpoints)
            }
            #expect(gateCalls >= deniedAt)
            #expect(!h.journal.events.contains("confirm"))
            if deniedAt <= 2 {
                #expect(h.checkpoints.written.isEmpty)
            } else {
                #expect(h.checkpoints.written.first?.state == .pending)
                #expect(!h.checkpoints.written.contains { $0.state == .failed })
            }
        }
    }

    @Test func postCheckpointWindowGroupOrSelectedRowDriftNeverPressesConfirm() throws {
        for drift in 0..<3 {
            let h = try harness(withSheet: false)
            let hooks = SubmitHooks(beforeIrreversible: {
                switch drift {
                case 0:
                    let frame = try #require(try h.window.frame())
                    h.fake.mutate(h.window.handle, attribute: AXAttribute.frame,
                                  to: .rect(frame.offsetBy(dx: 20, dy: 0)))
                case 1:
                    let title = try #require(h.reader.layout.activeTitle)
                    h.fake.mutate(title.handle, attribute: AXAttribute.value, to: .string("另一个合成群"))
                default:
                    let sheet = try #require(try GroupPickerSheet.locate(window: h.window))
                    let table = try #require(sheet.selectedTable)
                    h.fake.replaceChildren(of: table.handle,
                                           with: [GroupPickerTests.selectedRowNode(named: "王五", y: 388)])
                }
            })
            #expect(throws: ActionError.self) { try add(h, ["王五"], hooks: hooks) }
            #expect(h.checkpoints.written.first?.state == .pending)
            #expect(!h.journal.events.contains("confirm"))
        }
    }

    /// (13) Finding 5 — 确定 that never enables (the client refused the selection): 取消 is pressed
    /// and the call is `ACTION_UNAVAILABLE(确定)`, with no checkpoint, because nothing irreversible
    /// was attempted.
    @Test func aConfirmButtonThatNeverEnablesIsActionUnavailable() throws {
        let h = try harness(withSheet: false, confirmStaysDisabled: true)
        #expect(throws: ActionError.actionUnavailable("确定")) { try add(h, ["王五"]) }
        #expect(h.journal.returns == 1 && h.journal.events == ["header", "cancel"])
        #expect(h.checkpoints.written.isEmpty)
    }

    /// (14) Finding 5 — a 邀请 row that names only SOME of the people this call added proves nothing
    /// about the others, so the verdict stays `unknown`. Two members are added here (the fixture's
    /// 王五 plus a copy of that row under a second name) and the client names one of them.
    @Test func anInvitationRowNamingOnlyOneOfTwoAddedMembersIsNotEvidence() throws {
        let h = try harness(withSheet: false, confirm: .closesAndWritesAPartialInvitationRow)
        let out = try add(h, ["王五", "赵六"])
        #expect(out.added == ["王五", "赵六"] && out.skipped.isEmpty)
        #expect(out.state == .unknown && out.evidence == "no-evidence" && out.before == 3 && out.after == 3)
    }

    /// (15) Finding 5 — `群成员·N` is the SIDE PANEL's own heading. The same words elsewhere in the
    /// window — here the external-group banner under the header title — sit far from the right edge
    /// and are laid out first, and must not be mistaken for the client's count: this call still
    /// reports 3 → 4, not 99.
    @Test func aMemberCountLookAlikeOutsideTheSidePanelIsIgnored() throws {
        let h = try harness(withSheet: false, confirm: .closesAndGrowsTheCount, decoyBanner: true)
        let out = try add(h, ["王五"])
        #expect(out.before == 3 && out.after == 4)
        #expect(out.state == .succeeded && out.evidence == "count 3→4")
    }

    /// (15b) The side panel is the split pane right of the chat, measured from the live message
    /// viewport rather than a band at the window's right edge. A panel dragged wider than the
    /// recorded one (from x 1500) still yields the count; a row quoting 群成员·9 inside the chat,
    /// near its right edge (x 1682, within the old 240 pt band), never does.
    @Test func theMemberCountIsReadFromTheSidePanelRightOfTheLiveChat() throws {
        let wide = try harness(withSheet: false, confirm: .closesAndGrowsTheCount, memberPanelMinX: 1500, memberCountX: 1520)
        let widened = try add(wide, ["王五"])
        #expect(widened.before == 3 && widened.after == 4 && widened.evidence == "count 3→4")

        let h = try harness(withSheet: false, confirm: .closesAndGrowsTheCount)
        let messageTable = try #require(h.fake.handle(atPath: GroupFixture.messageTablePath))
        h.fake.appendChild(to: messageTable, node: AXNode(role: AXRole.row, subrole: "AXTableRow",
            frame: CGRect(x: 311, y: 900, width: 1379, height: 30), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 900, width: 1379, height: 30),
                       children: [GroupFixture.text("群成员·9", x: 1682, y: 906, w: 6)]),
            ]))
        let out = try add(h, ["王五"])
        #expect(out.before == 3 && out.after == 4 && out.evidence == "count 3→4")
    }

    /// (15c) Without a message viewport there is no chat edge to measure the panel from: the count
    /// is unreadable and the conversation is not treated as a group.
    @Test func aMemberCountWithoutAMessageViewportIsNotRead() throws {
        let h = try harness(withSheet: false)
        let chat = try #require(h.fake.handle(atPath: [0, 2]))
        h.fake.replaceChildren(of: chat, with: [])
        #expect(WeComActions.memberCount(reader: try WeComReader(window: h.fake.rootElement)) == nil)
    }

    /// (16) Finding 5 — the client rebuilds the side panel while the sheet tears down, so a poll can
    /// land when the heading is not readable. That is not "this group has no count": the outcome
    /// reports the last count the client actually showed instead of overwriting it with nil.
    @Test func aCountThatGoesUnreadableMidPollKeepsTheLastValueItShowed() throws {
        let h = try harness(withSheet: false, confirm: .closesOnly)
        let countHandle = try #require(h.countHandle)
        var reads = 0
        // Armed only past the press, so the `before` read is untouched: the panel answers the first
        // poll and is gone from the second on.
        let hooks = SubmitHooks(afterIrreversible: {
            h.fake.onRead = { handle, name in
                guard name == AXAttribute.value, handle == countHandle else { return }
                reads += 1
                if reads >= 2 { h.fake.mutate(countHandle, attribute: AXAttribute.value, to: nil) }
            }
        })
        let out = try add(h, ["王五"], hooks: hooks)
        #expect(reads >= 2)                     // the panel really did go unreadable mid-loop
        #expect(out.state == .unknown && out.evidence == "no-evidence" && out.before == 3 && out.after == 3)
    }

    /// (17) Task 5 — 确定 pressed but the sheet stays open: nothing was added (unlike (5)'s `unknown`,
    /// where the sheet DID close), so the verdict must be `failed`, not `unknown` — safe to run again.
    /// `closeGroupPicker` presses 取消 exactly once so the client is not left half-filled, and the
    /// checkpoint's `.failed` write happens right after that cancel — a best-effort write past the
    /// point that matters, like every other checkpoint update on this path, but still readable back
    /// from the store since `RecordingCheckpoints.write` never itself fails.
    @Test func aStillOpenSheetAfterConfirmIsFailedWithOneCancel() throws {
        let h = try harness(withSheet: false, confirm: .staysOpen)
        let out = try add(h, ["王五"])
        #expect(out.state == .failed && out.evidence == "sheet-still-open")
        #expect(out.added == ["王五"] && out.before == 3 && out.after == nil)
        #expect(h.journal.events == ["header", "checkpoint", "confirm", "cancel", "checkpoint(failed)"])
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .failed)
    }

    /// (18) Task 5 — the 确定 press itself throws (as in (11)) AND the sheet stays open, unlike (11)
    /// where the hook closes it despite the throw. A throw is not evidence either way, so the verdict
    /// follows the same closed/open split as a press that returns normally: open ⇒ `failed`, one 取消.
    /// `injectedFailures` is keyed by action name, not by element, so it would also catch
    /// `closeGroupPicker`'s own 取消 press; `afterIrreversible` clears it right after the confirm
    /// attempt so that cancel is a real AX press instead of throwing the same armed error again.
    @Test func aConfirmThatThrowsAndLeavesTheSheetOpenIsFailedWithOneCancel() throws {
        let h = try harness(withSheet: false, confirm: .staysOpen)
        let hooks = SubmitHooks(beforeIrreversible: {
            h.fake.injectedFailures["action:\(AXAction.press)"] = .cannotComplete("AXPress 确定")
        }, afterIrreversible: {
            h.fake.injectedFailures["action:\(AXAction.press)"] = nil
        })
        let out = try add(h, ["王五"], hooks: hooks)
        #expect(out.state == .failed && out.evidence == "sheet-still-open")
        #expect(out.details["confirmThrew"] == "true" && out.details["closed"] == "false")
        #expect(out.added == ["王五"] && out.before == 3 && out.after == nil)
        #expect(h.journal.events == ["header", "checkpoint", "cancel", "checkpoint(failed)"])   // no "confirm": the throw preempted the fake's own press reaction
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .failed)
    }

    /// (19) Review F8(a) — the ordinary live path, which the fixture could not reach before: no sheet
    /// is up when the call starts, and the header press is what makes the client hang one off the
    /// window. Everything after that is the normal flow.
    @Test func theHeaderPressItselfBringsUpTheSheetAndTheFlowProceeds() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        let out = try add(h, ["李四", "王五"])
        #expect(out.state == .succeeded && out.evidence == "count 3→4" && out.added == ["王五"])
        #expect(h.journal.events == ["header", "checkpoint", "confirm", "checkpoint(succeeded)"])
        #expect(Self.pressedXs(h.fake).first == 1879)      // one press, the rightmost button
    }

    @Test func visualChoicePressesOnlyTheChosenAXCandidate() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        var actions = h.actions
        actions.selectAddMembersHeaderButton = { _, candidates, _ in candidates.last }
        let out = try actions.addGroupMembers(["王五"], target: Self.target, dryRun: true,
                                              app: h.window, window: h.window, reader: h.reader,
                                              checkpoints: h.checkpoints)
        #expect(out.evidence == "dry-run")
        #expect(Self.pressedXs(h.fake).first == 1839)
        #expect(h.journal.events == ["header", "cancel"])
    }

    @Test func boundedPlannerChoosesOnlyAGroupHeaderButton() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        let candidates = try WeComActions.headerButtons(layout: h.reader.layout)
        let selected = try #require(candidates.last)
        var actions = h.actions
        var calls = 0
        actions.visualSelect = { _, goal, kinds, title, eligible, _ in
            calls += 1
            if case .control(.addGroupMembers) = goal {} else { Issue.record("wrong group header goal") }
            #expect(kinds == [.press] && title == GroupFixture.groupTitle)
            #expect(eligible.contains { $0.handle == selected.handle })
            return AIPlannerCandidate(id: "C0", kind: .press, element: selected,
                                      role: AXRole.button, frame: try #require(try selected.frame()))
        }
        let out = try actions.addGroupMembers(["王五"], target: Self.target, dryRun: true,
                                              app: h.window, window: h.window, reader: h.reader,
                                              checkpoints: h.checkpoints)
        #expect(out.evidence == "dry-run" && calls == 1)
        #expect(Self.pressedXs(h.fake).first == 1839)
    }

    @Test func boundedPlannerNoChoiceStopsBeforeHeaderPress() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        var actions = h.actions
        actions.visualSelect = { _, _, _, _, _, _ in nil }
        #expect(throws: ActionError.actionUnavailable("添加群成员")) {
            try actions.addGroupMembers(["王五"], target: Self.target, dryRun: true,
                                        app: h.window, window: h.window, reader: h.reader,
                                        checkpoints: h.checkpoints)
        }
        #expect(h.fake.recordedActions.isEmpty)
    }

    @Test func exactAXHelpNameBypassesCloudVision() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        let named = try #require(try WeComActions.headerButtons(layout: h.reader.layout).first)
        h.fake.mutate(named.handle, attribute: AXAttribute.help, to: .string("添加群成员"))
        var visualCalls = 0
        var actions = h.actions
        actions.selectAddMembersHeaderButton = { _, _, _ in visualCalls += 1; return nil }
        let out = try actions.addGroupMembers(["王五"], target: Self.target, dryRun: true,
                                              app: h.window, window: h.window, reader: h.reader,
                                              checkpoints: h.checkpoints)
        #expect(out.evidence == "dry-run")
        #expect(visualCalls == 0)
        #expect(Self.pressedXs(h.fake).first == 1879)
    }

    @Test func uncertainVisualChoiceNeverPressesAHeaderButton() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        var actions = h.actions
        actions.selectAddMembersHeaderButton = { _, _, _ in nil }
        #expect(throws: ActionError.actionUnavailable("添加群成员")) {
            try actions.addGroupMembers(["王五"], target: Self.target, dryRun: true,
                                        app: h.window, window: h.window, reader: h.reader,
                                        checkpoints: h.checkpoints)
        }
        #expect(h.fake.recordedActions.isEmpty)
    }

    @Test func visualChoiceOutsideAXCandidatesIsRejected() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembers])
        var actions = h.actions
        actions.selectAddMembersHeaderButton = { _, _, _ in h.window }
        #expect(throws: ActionError.actionUnavailable("添加群成员")) {
            try actions.addGroupMembers(["王五"], target: Self.target, dryRun: true,
                                        app: h.window, window: h.window, reader: h.reader,
                                        checkpoints: h.checkpoints)
        }
        #expect(h.fake.recordedActions.isEmpty)
    }

    /// (20) Review F5 — the sheet is ours, but the right-hand pane that carries 添加群成员 lags the
    /// outline by a poll. A wait that stops at "a sheet is up" would read the unnamed sheet as some
    /// other panel, cancel the REAL one and press the second, unknown header button; waiting for the
    /// title itself recognises it a poll later and carries on.
    @Test func aSheetWhoseTitleArrivesOnePollLateIsStillRecognised() throws {
        let h = try harness(withSheet: false, opensOnPress: [.addMembersWithALateTitle])
        let out = try add(h, ["王五"])
        #expect(out.state == .succeeded && out.evidence == "count 3→4" && out.added == ["王五"])
        #expect(h.journal.events == ["header", "checkpoint", "confirm", "checkpoint(succeeded)"])
        #expect(!h.journal.events.contains("cancel"))      // the real sheet was never cancelled
    }

    /// A different sheet after the press cannot be attributed safely to this command. Leave it
    /// intact and never press the second, unknown header button.
    @Test func aPressThatOpensAnotherSheetStopsWithoutCancellingIt() throws {
        let h = try harness(withSheet: false, opensOnPress: [.anotherSheet, .addMembers])
        #expect(throws: ActionError.actionUnavailable("添加群成员")) { try add(h, ["王五"]) }
        #expect(h.journal.events == ["header"] && h.checkpoints.written.isEmpty)
        #expect(try GroupPickerSheet.locate(window: h.window) != nil)
        #expect(Self.pressedXs(h.fake).first == 1879)      // right to left, as recorded
    }

    /// A pre-existing foreign sheet remains the user's state. No header button is pressed.
    @Test func aStaleSheetIsRejectedBeforeTheHeaderButtonsArePressed() throws {
        let h = try harness(withSheet: true, initialSheet: .anotherSheet, opensOnPress: [.addMembers])
        #expect(throws: ActionError.actionUnavailable("添加群成员：已有弹窗")) { try add(h, ["王五"]) }
        #expect(h.journal.events.isEmpty && h.checkpoints.written.isEmpty)
        #expect(try GroupPickerSheet.locate(window: h.window) != nil)
        let rightmost = try #require(try WeComActions.headerButtons(layout: h.reader.layout).first)
        #expect(h.fake.recordedActions.filter { $0.handle == rightmost.handle }.isEmpty)
    }

    /// (23) Review F4 — adding members is a server round trip, so the sheet can take noticeably longer
    /// to go away than a local repaint: the close wait gets `addMembersTimeout`, not the general
    /// `verifyTimeout`. Here the client closes it only ten polls in, well past `verifyTimeout` — with
    /// the old clock that read as "确定 did not take" and reported `failed`, i.e. "nothing was added"
    /// about an add that went through. Nothing else changes, so the honest verdict is `unknown`.
    @Test func aSheetThatTakesAServerRoundTripToCloseIsNotReportedAsFailed() throws {
        let h = try harness(withSheet: false, confirm: .closesOnTheNthPollAndNothingElse(10),
                            verifyTimeout: 0.03, addMembersTimeout: 1)
        let out = try add(h, ["王五"])
        #expect(out.state == .unknown && out.evidence == "no-evidence")
        #expect(out.details["closed"] == "true" && out.added == ["王五"])
        #expect(h.journal.events == ["header", "checkpoint", "confirm", "checkpoint(unknown)"])   // no 取消: the sheet closed by itself
        let id = try #require(out.details["checkpointID"])
        #expect(try h.checkpoints.load(id: id)?.state == .unknown)
    }

    /// A foreign sheet is never cancelled or retried, regardless of whether its Cancel button would
    /// work. This also protects a concurrently opened user panel.
    @Test func aForeignSheetThatSurvivesItsCancelStopsTheLoopBeforeTheSecondButton() throws {
        let h = try harness(withSheet: false, opensOnPress: [.anotherSheet], cancelIsIneffective: true)
        #expect(throws: ActionError.actionUnavailable("添加群成员")) { try add(h, ["王五"]) }
        #expect(h.journal.events == ["header"])
        let headerButtons = try WeComActions.headerButtons(layout: h.reader.layout)
        let rightmost = try #require(headerButtons.first)
        let leftmost = try #require(headerButtons.last)
        #expect(h.fake.recordedActions.filter { $0.handle == rightmost.handle }.count == 1)
        #expect(h.fake.recordedActions.filter { $0.handle == leftmost.handle }.count == 0)
        #expect(h.checkpoints.written.isEmpty && h.journal.returns == 0)
    }
}
