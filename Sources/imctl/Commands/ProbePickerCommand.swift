import AppKit
import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

/// Diagnostic for the 发起群聊 sheet: presses the + button of the 消息 view,
/// reports what opened (sheet / menu / nothing) and cancels it again.
struct ProbePickerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "picker",
        abstract: "Press the + button of the 消息 view, report what opens (发起群聊 sheet, a menu, nothing), dump the tree, then cancel."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Seconds to wait after the press before scanning.") var settle: Double = 1.0
    @Option(help: "Write the application tree (redacted unless --no-redact) here after the press.") var dump: String?
    @Flag(name: .customLong("keep-open"), help: "Leave whatever opened on screen.") var keepOpen = false
    @Flag(help: "Make the client frontmost first (AXFrontmost).") var frontmost = false
    @Flag(name: .customLong("via-shortcut"), help: "Use the client's ⌘N (发起群聊) instead of AXPress on +.") var viaShortcut = false
    @Flag(help: "Try the 我的客户 expansion attempts one by one (AXDisclosing, select row, row button), reporting rows after each.") var expand = false
    @Option(help: "Type this into the sheet's search field (AXValue) and report the rows.") var search: String?
    @Flag(help: "After --search: select the result row (AXSelectedRows, then the row button) and report the chosen list; still cancels.") var select = false
    @Flag(help: "With --select: also try focusing the search field and posting the pid-level Return key.") var enter = false
    @Option(help: "One explicit path, reported with the chosen list's texts: search-enter (type, focus field, Return) or select-enter (AXSelectedRows on the row, focus field, Return).") var strategy: String?

    func chosenTexts(_ sheet: GroupPickerSheet, redact: (String?) -> String?) -> [String] {
        guard let table = sheet.selectedTable else { return [] }
        return ((try? table.children()) ?? []).filter { (try? $0.role()) == AXRole.row }.map { row in
            row.descendants(maxDepth: 3, maxNodes: 40).compactMap { c -> String? in
                guard let r = try? c.role(), r == AXRole.textArea || r == AXRole.staticText, let v = try? c.valueString(), !v.isEmpty else { return nil }
                return redact(v) ?? "-"
            }.joined(separator: "/")
        }
    }

    func runStrategy(_ name: String, sheet: GroupPickerSheet, member: String, redact: (String?) -> String?) throws {
        let pid = try sheet.sheet.pid()
        print("strategy \(name) for \(redact(member) ?? "-"):")
        switch name {
        case "search-enter":
            guard let field = sheet.searchField else { throw ValidationError("no search field") }
            try field.setAttribute(AXAttribute.value, to: .string(member))
            Thread.sleep(forTimeInterval: settle)
            let results = try sheet.rows()
            print("   results: \(results.map { "\(redact($0.name) ?? "-")/\($0.section)/\($0.tag ?? "-")" })")
            if (try? field.isSettable(AXAttribute.focused)) == true { try field.setAttribute(AXAttribute.focused, to: .bool(true)) }
            try KeystrokeInjector.postReturn(toPid: pid, control: false)
        case "select-enter":
            guard let row = try sheet.rows().first(where: { $0.name == member })?.row else { throw ValidationError("member not listed") }
            try sheet.outline.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
            Thread.sleep(forTimeInterval: settle)
            if let field = sheet.searchField, (try? field.isSettable(AXAttribute.focused)) == true { try field.setAttribute(AXAttribute.focused, to: .bool(true)) }
            try KeystrokeInjector.postReturn(toPid: pid, control: false)
        default: throw ValidationError("unknown strategy \(name)")
        }
        Thread.sleep(forTimeInterval: settle)
        print("   chosen=\(try sheet.selectedCount()) texts=\(chosenTexts(sheet, redact: redact)) 完成 enabled=\(String(describing: try sheet.doneButton?.isEnabled()))")
        print("   search field value now: \(redact((try? sheet.searchField?.valueString()) ?? "") ?? "-")")
    }

    /// Every AX way of choosing a member we can think of, reported one by one; stops when the chosen list grows.
    func trySelecting(_ row: AXElement, in sheet: GroupPickerSheet, label: String) throws {
        let cell = try row.children().first { (try? $0.role()) == AXRole.cell } ?? row
        print("selecting (\(label)): row actions=\((try? row.actions()) ?? []) settable=\(["AXSelected", "AXFocused", "AXDisclosing"].filter { (try? row.isSettable($0)) == true }) cell actions=\((try? cell.actions()) ?? [])")
        for (i, c) in (try cell.children()).enumerated() {
            print("   child \(i) \((try? c.role()) ?? "?") frame=\((try? c.frame()).map { "\(Int($0!.minX)),\(Int($0!.minY)) \(Int($0!.width))×\(Int($0!.height))" } ?? "-") actions=\((try? c.actions()) ?? []) settable=\(["AXSelected", "AXFocused", "AXValue"].filter { (try? c.isSettable($0)) == true })")
        }
        let before = try sheet.selectedCount()
        func report(_ what: String) throws -> Bool {
            Thread.sleep(forTimeInterval: settle)
            let n = try sheet.selectedCount()
            print("   \(what): chosen \(before) -> \(n) 完成 enabled=\(String(describing: try sheet.doneButton?.isEnabled()))")
            return n > before
        }
        let strategies: [(String, () throws -> Void)] = [
            ("AXSelectedRows", { try sheet.outline.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle])) }),
            ("AXSelected=true on row", { try row.setAttribute(AXAttribute.selected, to: .bool(true)) }),
            ("AXPress on row", { try row.perform(AXAction.press) }),
            ("AXPress on cell", { try cell.perform(AXAction.press) }),
            ("AXPress on each pressable child", {
                for c in try cell.children() where ((try? c.actions()) ?? []).contains(AXAction.press) { try c.perform(AXAction.press) }
            }),
            ("AXFocused=true on row", { try row.setAttribute(AXAttribute.focused, to: .bool(true)) }),
            ("AXConfirm on search field", { guard let f = sheet.searchField else { throw ValidationError("no search field") }; try f.perform(AXAction.confirm) }),
            ("focus search field + Return (pid)", {
                guard enter, let f = sheet.searchField else { throw ValidationError("--enter not given") }
                if (try? f.isSettable(AXAttribute.focused)) == true { try f.setAttribute(AXAttribute.focused, to: .bool(true)) }
                try KeystrokeInjector.postReturn(toPid: try sheet.sheet.pid(), control: false)
            }),
        ]
        for (what, run) in strategies {
            do { try run() } catch { print("   \(what): \(error)"); continue }
            if try report(what) { return }
        }
    }

    /// Rows whose AXDisclosing is settable and false: collapsed groups.
    func collapsedGroups(_ sheet: GroupPickerSheet) -> [AXElement] {
        ((try? sheet.outline.children()) ?? []).filter { row in
            (try? row.role()) == AXRole.row && (try? row.isSettable(AXAttribute.disclosing)) == true && (try? row.bool(AXAttribute.disclosing)) == false
        }
    }

    func describeRows(_ sheet: GroupPickerSheet, redact: (String?) -> String?) -> [String] {
        var lines: [String] = []
        for (i, row) in ((try? sheet.outline.children()) ?? []).enumerated() where (try? row.role()) == AXRole.row {
            let cell = (try? row.children().first { (try? $0.role()) == AXRole.cell }) ?? row
            let texts = ((try? cell.children()) ?? []).compactMap { c -> String? in
                guard let r = try? c.role(), r == AXRole.textArea || r == AXRole.staticText, let v = try? c.valueString(), !v.isEmpty else { return nil }
                let shown = ProbeTreeSummary.keepTexts.contains(v) ? v : (redact(v) ?? "-")
                return "\(shown)@\(Int((try? c.frame())??.minX ?? 0))"
            }
            let f = (try? row.frame()) ?? .zero
            let disc = (try? row.attribute(AXAttribute.disclosing)).map { "\($0)" } ?? "-"
            let level = (try? row.attribute("AXDisclosureLevel")).map { "\($0)" } ?? "-"
            let settable = (try? row.isSettable(AXAttribute.disclosing)) == true
            let roles = ((try? cell.children()) ?? []).compactMap { try? $0.role() }.map { $0.replacingOccurrences(of: "AX", with: "") }
            lines.append("  #\(i) y=\(Int(f.minY)) h=\(Int(f.height)) level=\(level) disclosing=\(disc)\(settable ? "(settable)" : "") \(texts.joined(separator: " ")) [\(roles.joined(separator: ","))]")
        }
        let parsed = (try? sheet.rows()) ?? []
        lines.append("  parsed rows=\(parsed.count) customers=\(sheet.customers.count) selected=\((try? sheet.selectedCount()) ?? -1)")
        return lines
    }

    func run() throws {
        guard options.fromFixture == nil else { throw ValidationError("live only: this probe presses the + button") }
        let app = try ProbeSession.root(options)
        let window = try WeComWindowLocator.mainWindow(from: app)
        let redact = ProbeSession.redactor(options)
        let layout = try WeComLayout.locate(in: window)
        guard let plus = layout.plusButton else { throw ValidationError("no + button on the current view (not on 消息?)") }
        print("plus: \(ProbeTreeSummary.path(of: plus)) frame=\(try plus.frame().map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-") actions=\((try? plus.actions()) ?? [])")
        let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pid = try app.pid()
        if frontmost, (try? app.isSettable(AXAttribute.frontmost)) == true { try app.setAttribute(AXAttribute.frontmost, to: .bool(true)) }
        if viaShortcut {
            try KeystrokeInjector.postShortcut(.commandN, toPid: pid)
        } else {
            try plus.perform(AXAction.press)
        }
        defer { if let previous, previous != pid { NSRunningApplication(processIdentifier: previous)?.activate() } }
        Thread.sleep(forTimeInterval: settle)
        let node = try ProbeTreeSummary.dump(app: app, to: dump, raw: options.noRedact)
        print("overlays after +:")
        for line in ProbeTreeSummary.overlays(node) { print("  " + line) }
        let sheet = try GroupPickerSheet.locate(window: window)
        if let sheet {
            let rows = (try? sheet.rows()) ?? []
            print("sheet: found search=\(sheet.searchField != nil) done=\(sheet.doneButton != nil) cancel=\(sheet.cancelButton != nil) rows=\(rows.count) customers=\(sheet.customers.count)")
            for r in rows.prefix(6) { print("  row section=\(r.section) name=\(redact(r.name) ?? "-") tag=\(r.tag ?? "-")") }
        } else {
            print("sheet: not found")
        }
        if let sheet {
            print("rows on open:"); describeRows(sheet, redact: redact).forEach { print($0) }
            if expand, sheet.customers.isEmpty, let header = try sheet.customersHeaderRow() {
                let cell = try header.children().first { (try? $0.role()) == AXRole.cell } ?? header
                let attempts: [(String, () throws -> Void)] = [
                    ("AXDisclosing=true", { try header.setAttribute(AXAttribute.disclosing, to: .bool(true)) }),
                    ("AXSelectedRows=[header]", { try sheet.outline.setAttribute(AXAttribute.selectedRows, to: .elements([header.handle])) }),
                    ("press header button", {
                        guard let b = try cell.children().first(where: { (try? $0.role()) == AXRole.button }) else { throw ValidationError("no row button") }
                        try b.perform(AXAction.press)
                    }),
                ]
                for (label, attempt) in attempts {
                    do { try attempt(); print("attempt \(label): ok") } catch { print("attempt \(label): \(error)"); continue }
                    Thread.sleep(forTimeInterval: settle)
                    describeRows(sheet, redact: redact).forEach { print($0) }
                    if !sheet.customers.isEmpty { break }
                }
                // sub-groups (微信联系人) under 我的客户 are collapsed too
                var round = 0
                while sheet.customers.isEmpty, round < 3, let group = collapsedGroups(sheet).first(where: { ((try? $0.frame())??.minY ?? 0) > ((try? header.frame())??.minY ?? 0) }) {
                    round += 1
                    try group.setAttribute(AXAttribute.disclosing, to: .bool(true))
                    Thread.sleep(forTimeInterval: settle)
                    print("after disclosing sub-group \(round):"); describeRows(sheet, redact: redact).forEach { print($0) }
                }
            }
            if let strategy, let search {
                try runStrategy(strategy, sheet: sheet, member: search, redact: redact)
            } else if select, let search, let row = try sheet.rows().first(where: { $0.name == search })?.row {
                try trySelecting(row, in: sheet, label: "expanded list")
            }
            if strategy == nil, let search, let field = sheet.searchField {
                try field.setAttribute(AXAttribute.value, to: .string(search))
                Thread.sleep(forTimeInterval: settle)
                print("rows after search '\(search)':"); describeRows(sheet, redact: redact).forEach { print($0) }
                if select, let row = try sheet.rows().first(where: { $0.name == search })?.row {
                    try trySelecting(row, in: sheet, label: "search result")
                } else if select {
                    print("select: no parsed row named \(search)")
                }
                try? field.setAttribute(AXAttribute.value, to: .string(""))
            }
        }
        guard !keepOpen else { return }
        if let sheet, let cancel = sheet.cancelButton {
            try cancel.perform(AXAction.press)
            print("cancelled: \(try GroupPickerSheet.locate(window: window) == nil)")
        } else {
            for menu in app.descendants(maxDepth: 6, maxNodes: 2000) where (try? menu.role()) == "AXMenu" {
                if (try? menu.perform("AXCancel")) != nil { print("menu cancelled") }
            }
        }
    }
}
