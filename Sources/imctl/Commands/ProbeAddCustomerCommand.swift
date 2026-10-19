import AppKit
import ArgumentParser
import AXKit
import ControlCore
import Foundation
import WeComAdapter

/// Diagnostic for adding a customer by phone number (B12): 通讯录 › 新的客户 ›
/// 添加 (top right) opens the 添加客户 panel; typing a number lists matches
/// (微信 / 企业微信) each with an 添加 button. This probe opens the panel,
/// types the number through AX (`AXValue`), reports what the panel shows and
/// closes it again — it presses no 添加 button. Live only.
struct ProbeAddCustomerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "addcustomer",
        abstract: "Open 通讯录 › 新的客户 › 添加, type a phone number into the search field, report the result rows and close the panel; presses no 添加."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Phone number to search (never printed; only its length).") var phone: String
    @Option(help: "Seconds to wait after each step.") var settle: Double = 0.8
    @Option(help: "Write the application tree (redacted unless --no-redact) here while the panel is open.") var dump: String?
    @Flag(name: .customLong("keep-open"), help: "Leave the panel open.") var keepOpen = false
    @Flag(help: "Make the client frontmost (AXFrontmost) before pressing 添加.") var frontmost = false
    @Flag(name: .customLong("return"), help: "After typing, post one Return to the client's pid (the search only runs on a key; approved by the user 2026-09-16 12:09).") var postReturn = false

    /// On-screen windows of every process (CGWindowList; names may be empty without screen recording): tells us
    /// whether the panel belongs to another process when the client's own AX tree does not show it.
    static func windowsOnScreen() -> [String] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            guard let owner = w[kCGWindowOwnerName as String] as? String, let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
            let name = (w[kCGWindowName as String] as? String) ?? ""
            return "\(owner)\(name.isEmpty ? "" : " '\(name.count) chars'") [\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)×\(b["Height"] ?? 0)]"
        }
    }

    func run() throws {
        guard options.fromFixture == nil else { throw ValidationError("live only") }
        let app = try ProbeSession.root(options)
        let window = try WeComWindowLocator.mainWindow(from: app)
        let redact = ProbeSession.redactor(options)
        let pid = try app.pid()
        let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: [.openContacts], phase: .phase1))
        actions.trace = { print("  " + $0) }
        let opened = try actions.openContacts(app: app, window: window)
        print("contacts: \(opened.verified ? "reached" : "not reached") steps=\(opened.details["steps"] ?? "-")")
        Thread.sleep(forTimeInterval: settle)
        // the 添加 button: titled 添加, in the right half of the window, near its top
        let wf = try window.frame() ?? .zero
        let buttons = window.descendants(maxDepth: 14, maxNodes: 8000).filter { (try? $0.role()) == AXRole.button && (try? $0.title()) == "添加" }
        let described = buttons.map { b -> String in
            let f = (try? b.frame()).flatMap { $0 } ?? .zero
            return "添加@\(Int(f.minX - wf.minX)),\(Int(f.minY - wf.minY)) \(Int(f.width))×\(Int(f.height)) enabled=\((try? b.isEnabled()) ?? nil ?? true)"
        }
        print("添加 buttons in the window: \(described.isEmpty ? "-" : described.joined(separator: " | "))")
        // the page's own 添加: the one sibling of the pane's 新的客户 heading on its line (the action's own rule)
        let own = try WeComActions.addCustomerHeaderCandidates(window: window)
        guard own.count == 1, let add = own.first else {
            throw ValidationError("\(own.count) 添加 buttons beside the 新的客户 heading; expected exactly one")
        }
        if frontmost, (try? app.isSettable(AXAttribute.frontmost)) == true {
            try app.setAttribute(AXAttribute.frontmost, to: .bool(true))
            for _ in 0..<15 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { Thread.sleep(forTimeInterval: 0.1) }
            print("frontmost: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        }
        let before = Self.windowsOnScreen()
        if (try? add.isSettable(AXAttribute.focused)) == true { try? add.setAttribute(AXAttribute.focused, to: .bool(true)) }
        try add.perform(AXAction.press)
        Thread.sleep(forTimeInterval: settle)
        let afterPress = Self.windowsOnScreen()
        print("windows on screen: \(afterPress.count) (before \(before.count)); new: \(afterPress.filter { !before.contains($0) })")
        print("client windows (AXWindows): \((try? app.elements(AXAttribute.windows).count) ?? -1)")
        // what opened: the client shows the panel as a second AXWindow (live 2026-09-16); describe every window but the main one
        let node = try ProbeTreeSummary.dump(app: app, to: dump, raw: options.noRedact)
        _ = node
        var panel: AXElement?
        for w in (try? app.elements(AXAttribute.windows)) ?? [] where w.handle != window.handle {
            let f = (try? w.frame()).flatMap { $0 } ?? .zero
            let all = w.descendants(maxDepth: 12, maxNodes: 4000)
            var roles: [String: Int] = [:]
            for e in all { roles[(try? e.role()) ?? "?", default: 0] += 1 }
            let buttons = all.filter { (try? $0.role()) == AXRole.button }.map { "\((try? $0.title()) ?? "-")/\((try? $0.subrole()) ?? "-")" }
            let fields = all.filter { (try? $0.role()) == AXRole.textField || (try? $0.role()) == AXRole.textArea }.map { e -> String in
                let ef = (try? e.frame()).flatMap { $0 } ?? .zero
                return "\((try? e.role()) ?? "?")@\(Int(ef.minX)),\(Int(ef.minY)) \(Int(ef.width))×\(Int(ef.height)) placeholder=\((try? e.string(AXAttribute.placeholderValue)) ?? nil ?? "-") settable=\((try? e.isSettable(AXAttribute.value)) ?? false)"
            }
            let texts = all.filter { (try? $0.role()) == AXRole.staticText }.compactMap { try? $0.valueString() }.map { redact($0) ?? "-" }
            print("window \((try? w.subrole()) ?? "-") [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))] title=\(redact((try? w.title()) ?? "") ?? "-") roles=\(roles) buttons=\(buttons) fields=\(fields) texts=\(texts.prefix(12))")
            if panel == nil { panel = w }
        }
        guard let panel else { throw ValidationError("no second window opened after 添加") }
        let panelFields = panel.descendants(maxDepth: 12, maxNodes: 4000).filter { (try? $0.role()) == AXRole.textField || (try? $0.role()) == AXRole.textArea }
        guard let field = panelFields.first else { throw ValidationError("no search field in the 添加客户 panel") }
        print("search field: \(ProbeTreeSummary.path(of: field)) settable=\((try? field.isSettable(AXAttribute.value)) ?? false)")
        print("field actions: \((try? field.actions()) ?? []) focusSettable=\((try? field.isSettable(AXAttribute.focused)) ?? false)")
        if (try? field.isSettable(AXAttribute.focused)) == true { try? field.setAttribute(AXAttribute.focused, to: .bool(true)) }
        try field.setAttribute(AXAttribute.value, to: .string(phone))
        // a search box may only search on confirm (the header rename field needed AXConfirm): try it when offered
        var confirmed = false
        var rowsSeen = 0
        if postReturn {
            Thread.sleep(forTimeInterval: 0.3)
            try KeystrokeInjector.postReturn(toPid: pid, control: false)
            print("Return posted to pid \(pid)")
        }
        for tick in 0..<Int(max(settle, 1.5) * 10) {
            Thread.sleep(forTimeInterval: 0.1)
            rowsSeen = panel.descendants(maxDepth: 12, maxNodes: 4000).filter { (try? $0.role()) == AXRole.button && (try? $0.title()) == "添加" }.count
            if rowsSeen > 0 { break }
            if tick == 15, !postReturn, !confirmed, (try? field.actions())?.contains(AXAction.confirm) == true { try? field.perform(AXAction.confirm); confirmed = true; print("AXConfirm sent to the field") }
        }
        print("waited \(rowsSeen > 0 ? "until results" : "the full settle") confirmed=\(confirmed)")
        _ = try ProbeTreeSummary.dump(app: app, to: dump.map { $0.replacingOccurrences(of: ".json", with: "-results.json") }, raw: options.noRedact)
        let panelAll = panel.descendants(maxDepth: 12, maxNodes: 4000)
        var roles: [String: Int] = [:]
        for e in panelAll { roles[(try? e.role()) ?? "?", default: 0] += 1 }
        print("panel after typing \(phone.count) digits: roles=\(roles) field value length=\((try? field.valueString())??.count ?? -1)")
        for e in panelAll.prefix(60) {
            let ef = (try? e.frame()).flatMap { $0 } ?? .zero
            let role = (try? e.role()) ?? "?"
            let value = (try? e.valueString()).flatMap { $0 } ?? ""
            let title = (try? e.title()).flatMap { $0 } ?? ""
            print("   \(role)/\((try? e.subrole()).flatMap { $0 } ?? "-") @\(Int(ef.minX - wf.minX)),\(Int(ef.minY - wf.minY)) \(Int(ef.width))×\(Int(ef.height)) title=\(redact(title) ?? "-") value=\(value == phone ? "<phone>" : (redact(value) ?? "-")) desc=\((try? e.axDescription()).flatMap { $0 }.map { redact($0) ?? "-" } ?? "-") actions=\((try? e.actions()) ?? [])")
        }
        // result rows: 添加 buttons inside the panel, with the texts left of them (sources, names)
        let adds = panelAll.filter { (try? $0.role()) == AXRole.button && (try? $0.title()) == "添加" }
        print("result 添加 buttons: \(adds.count)")
        for (i, b) in adds.enumerated() {
            let f = (try? b.frame()).flatMap { $0 } ?? .zero
            let texts = panelAll.filter { e in
                guard let r = try? e.role(), r == AXRole.staticText || r == AXRole.textArea, let tf = try? e.frame() else { return false }
                return abs(tf.midY - f.midY) < 30 && tf.maxX <= f.minX
            }.compactMap { try? $0.valueString() }
            let images = panelAll.filter { e in
                guard (try? e.role()) == AXRole.image, let tf = try? e.frame() else { return false }
                return abs(tf.midY - f.midY) < 30 && tf.maxX <= f.minX
            }.map { e -> String in let ef = (try? e.frame()).flatMap { $0 } ?? .zero; return "\(Int(ef.width))×\(Int(ef.height)) desc=\((try? e.axDescription()) ?? nil ?? "-")" }
            print("  result \(i): texts=\(texts.map { redact($0) ?? "-" }) images=\(images) button@\(Int(f.minX - wf.minX)),\(Int(f.minY - wf.minY)) enabled=\((try? b.isEnabled()) ?? nil ?? true)")
        }
        if !keepOpen {
            // close: the panel's close button (AXCloseButton subrole) or 取消
            let closers = panel.descendants(maxDepth: 12, maxNodes: 4000).filter { e in
                (try? e.role()) == AXRole.button && ((try? e.subrole()) == "AXCloseButton" || (try? e.title()) == "取消" || (try? e.title()) == "关闭")
            }
            if let c = closers.first { try? c.perform(AXAction.press); print("closed via \((try? c.title()) ?? "-")/\((try? c.subrole()) ?? "-")") }
            else { print("no close button in the panel; leaving it (close it by hand)") }
            Thread.sleep(forTimeInterval: settle)
            _ = try? actions.returnToMessages(window: window)
            if let previous, previous != pid { NSRunningApplication(processIdentifier: previous)?.activate() }
        }
    }
}
