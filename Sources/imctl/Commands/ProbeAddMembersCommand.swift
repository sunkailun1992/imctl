import ArgumentParser
import AXKit
import ControlCore
import Foundation
import WeComAdapter

/// Diagnostic for the 添加群成员 sheet (B14): selects an allowlisted conversation, then opens the
/// sheet the same way `group.addMembers` itself does — `WeComActions.openAddMembersSheet` presses
/// the group header's own untitled buttons right to left (`AddGroupMembers.headerButtons`),
/// cancelling anything else that opens, until a sheet titled 添加群成员 appears. Reports its rows
/// redacted by default, then always cancels. This probe never types a name to select it, never
/// posts Return, and never presses 确定 — the same look-only guarantee `ProbePickerCommand` gives
/// for the 发起群聊 sheet, applied to the add-members variant of the same widget family (Task 3).
/// Live only: there is no recorded fixture with header buttons wired to press.
///
/// Task 7 fix (2026-09-23): `openAddMembersSheet` presses real header buttons with no `authorize`
/// of its own — it is the lower half of `WeComActions.addGroupMembers`, which checks
/// `.addGroupMembers` itself before calling it, but this probe called it directly. `run()` now runs
/// that same check (`gate`, below) before `selectConversation` even runs, so a target that is
/// neither compiled in, nor in `policy.json`, nor covered by `allowAll` is refused before any AX
/// contact at all, not just before the press.
struct ProbeAddMembersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "addmembers",
        abstract: "Open an existing group's 添加群成员 sheet, report its rows (redacted) and the 确定 state, then cancel. Never selects a member or presses 确定."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Exact title of the group to probe; must be allowlisted.") var target: String
    @Option(help: "Type this into the sheet's search field and wait for the filter (never confirmed with Return).") var search: String?
    @Option(help: "Write the application tree (redacted unless --no-redact) here once the sheet is open.") var dump: String?
    @Option(help: "Seconds to wait between steps.") var settle: Double = 0.7

    /// The compiled allowlist plus whatever `policy.json` additionally allows — the same two
    /// sources the real `group.addMembers` action is judged against. `selectConversation`'s target
    /// check is a no-op unless `SendPolicy.gateReads` is on (B10: opening a conversation is not
    /// gated by default), exactly as for `ProbeSelectCommand`; loading the file here still keeps
    /// this probe's policy accurate to what the live action would see once reads are gated.
    /// Phase 1 with `.addGroupMembers` enabled — `ProbeSubmitCommand`'s opt-in pattern — so `gate`
    /// below judges this probe's target exactly as the real action would, rather than treating
    /// `.addGroupMembers` as permanently phase-0-forbidden and never reachable.
    static func policy() throws -> ActionPolicy {
        ActionPolicy(allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: [.selectConversation, .addGroupMembers],
                     phase: .phase1, sendPolicy: try SendPolicy.load(from: SendPolicy.defaultURL))
    }

    /// The same authorize call `WeComActions.addGroupMembers` makes before touching anything,
    /// against a bare title: this probe has not read the client yet, so there is no row / header /
    /// message evidence to refine the type with — only what `WeComActions.authorize` itself falls
    /// back to for an unset `resolvedTarget`, a `ResolvedTarget(title:)` of type `unknown` and no
    /// ids. `unknown` never matches a type rule, so only a compiled-in title, a `policy.json`
    /// title, or `allowAll` can pass it. Pure and standalone so `ProbeAddMembersTests` can cover
    /// allowed vs refused targets without a live client.
    static func gate(policy: ActionPolicy, target: String) throws {
        try policy.authorize(.addGroupMembers, resolved: ResolvedTarget(title: target))
    }

    /// One row, redacted by default: never the name or section text, only their character counts,
    /// plus the source and whether the client already marked this person a member of the group
    /// (`checkbox selected disabled`, Task 3). `--no-redact` swaps both counts for the real
    /// strings; the shape of the line (and every other field) stays the same either way.
    static func formatRow(index: Int, row: PickerContact, noRedact: Bool) -> String {
        let identity = noRedact ? "name=\(row.name)" : "len=\(row.name.count)"
        let section = noRedact ? "section=\(row.section)" : "section=\(row.section.count)c"
        return "#\(index) \(identity) \(section) source=\(row.source) disabled=\(row.disabled)"
    }

    static func formatRows(_ rows: [PickerContact], noRedact: Bool) -> [String] {
        rows.enumerated().map { formatRow(index: $0.offset + 1, row: $0.element, noRedact: noRedact) }
    }

    func run() throws {
        guard options.fromFixture == nil else { throw ValidationError("live only: this probe opens the client's 添加群成员 sheet") }
        let policy = try Self.policy()
        do {
            try Self.gate(policy: policy, target: target)
        } catch let e as PolicyError {
            print("policy: \(e)")
            throw e
        }
        print("policy: allowed")

        let app = try ProbeSession.root(options)
        let window = try WeComWindowLocator.mainWindow(from: app)
        var actions = WeComActions(policy: policy)
        actions.trace = { print("step: \($0)") }
        let visionSettings = try? CloudVisionSettings.loadOrDefault()
        if FileManager.default.fileExists(atPath: CloudVisionSettings.defaultURL.path), visionSettings == nil {
            actions.selectAddMembersHeaderButton = { _, _, _ in throw CloudVisionError.requestFailed }
        } else if visionSettings?.cloudEnabled == true {
            actions.selectAddMembersHeaderButton = { reader, candidates, expectedTitle in
                let current = try CloudVisionSettings.loadOrDefault()
                return try CloudHeaderButtonTargeting.select(reader: reader, candidates: candidates,
                                                            expectedTitle: expectedTitle, settings: current)
            }
        }

        _ = try actions.selectConversation(target, reader: try WeComReader(window: window))
        print("step: target selected")
        Thread.sleep(forTimeInterval: settle)
        let currentReader = try WeComReader(window: window)
        let headerCandidates = try WeComActions.headerButtons(layout: currentReader.layout)
        let windowFrame = currentReader.layout.windowFrame
        let frameSummaries = try headerCandidates.map { candidate -> String in
            guard let frame = try candidate.frame() else { return "missing" }
            let help = (try? candidate.string(AXAttribute.help)) ?? ""
            let value = (try? candidate.valueString()) ?? ""
            let hasAddLabel = [help, value].contains { $0 == "添加群成员" || $0 == "Add Group Members" }
            return "x=\(Int(frame.minX - windowFrame.minX)) y=\(Int(frame.minY - windowFrame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height)) addLabel=\(hasAddLabel)"
        }
        print("step: header candidates=\(headerCandidates.count) [\(frameSummaries.joined(separator: "; "))]")

        // Reuses the exact flow `group.addMembers` opens with: header buttons right to left, any
        // other sheet that opens along the way is cancelled before the next button is tried.
        let sheet = try actions.openAddMembersSheet(window: window, reader: try WeComReader(window: window), expectedTitle: target)
        do {
            Thread.sleep(forTimeInterval: settle)
            if let search {
                guard let field = sheet.searchField else { throw ValidationError("no search field on the 添加群成员 sheet") }
                try field.setAttribute(AXAttribute.value, to: .string(search))
                Thread.sleep(forTimeInterval: settle)
            }
            if let dump { _ = try ProbeTreeSummary.dump(app: app, to: dump, raw: options.noRedact) }

            let rows = try sheet.rows()
            print("rows: \(rows.count)")
            for line in Self.formatRows(rows, noRedact: options.noRedact) { print(line) }
            let doneEnabled: Bool
            if let done = sheet.doneButton { doneEnabled = (try? done.isEnabled()) ?? true } else { doneEnabled = false }
            print("确定 enabled=\(doneEnabled)")
        } catch {
            // Whatever went wrong, this probe still only ever looks: close the sheet before the error propagates.
            try? actions.closeGroupPicker(sheet, window: window)
            throw error
        }
        try actions.closeGroupPicker(sheet, window: window)
        print("取消 pressed: closed=\(try GroupPickerSheet.locate(window: window) == nil)")
    }
}
