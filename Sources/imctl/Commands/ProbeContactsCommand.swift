import AppKit
import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

struct ContactsProbeOutput: Codable {
    struct Step: Codable {
        var step: Int
        var key: String
        var scanMs: Int
        var nodes: Int
        var showing: Bool
        var leftTexts: [String]
    }

    var pid: Int32
    var frontmostSet: Bool
    var steps: [Step]
    var reached: Bool
    var cards: [String]
    var overlays: [String] = []
    var finishButton: String?
    var acceptStatus: String?
    var returned: Bool?

    func render() -> String {
        var lines = ["pid: \(pid) frontmostSet: \(frontmostSet)"]
        lines += steps.map { s in
            "step \(s.step) \(s.key): showing=\(s.showing) nodes=\(s.nodes) scan=\(s.scanMs)ms left=\(s.leftTexts.joined(separator: " | "))"
        }
        lines.append("reached: \(reached) cards: \(cards.isEmpty ? "-" : cards.joined(separator: "; "))")
        if !overlays.isEmpty { lines.append("overlays after 接受:"); lines += overlays.map { "  " + $0 } }
        if let finishButton { lines.append("完成 button: \(finishButton)") }
        if let acceptStatus { lines.append("status after 完成: \(acceptStatus)") }
        if let returned { lines.append("returned to 消息: \(returned)") }
        return lines.joined(separator: "\n")
    }
}

/// Diagnostic for the 通讯录 recipe: ⌘8, then ⌃Tab one step at a time,
/// scanning the window after each key so the log shows which step reveals
/// the signature texts (新的客户 + 智能机器人 / 添加成员...). Posts only the
/// client's own tab shortcuts to its pid (the approved exception) and comes
/// back through wxwork://conversationlist. Live only.
struct ProbeContactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Step ⌘8 / ⌃Tab through the client's tabs until 通讯录 shows, reporting each step; returns via the conversation-list deep link."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Maximum ⌃Tab steps after ⌘8.") var steps: Int = 8
    @Option(help: "Seconds to wait after each key before scanning.") var settle: Double = 0.6
    @Flag(name: .customLong("scan-only"), help: "Scan the current view; press nothing and do not return.") var scanOnly = false
    @Flag(name: .customLong("no-return"), help: "Stay on the reached view.") var noReturn = false
    @Option(help: "On 新的客户, press 接受 on this pending card and report the popover that opens (设置备注名 …).") var accept: String?
    @Option(help: "Write the application tree (redacted unless --no-redact) here after the last step.") var dump: String?
    @Flag(help: "With --accept: press the popover's 完成 and report the card's status afterwards.") var finish = false

    func scan(window: AXElement, step: Int, key: String, redact: (String?) -> String?) -> ContactsProbeOutput.Step {
        let started = Date()
        let texts = WeComContactsView.texts(in: window)
        let showing = WeComContactsView.isShowing(window: window)
        let left = texts.filter { ((try? $0.1.frame())??.minX ?? 999) < 400 }.map(\.0)
        let signature = Set([WeComContactsView.newCustomersTitle]).union(WeComContactsView.signatureTexts)
        let shown = left.prefix(12).map { signature.contains($0) ? $0 : (redact($0) ?? "-") }
        return .init(step: step, key: key, scanMs: Int(Date().timeIntervalSince(started) * 1000), nodes: texts.count, showing: showing, leftTexts: Array(shown))
    }

    func run() throws {
        guard options.fromFixture == nil else { throw ValidationError("live only: this probe presses the client's tab shortcuts") }
        let app = try ProbeSession.root(options)
        let window = try WeComWindowLocator.mainWindow(from: app)
        let redact = ProbeSession.redactor(options)
        let pid = try app.pid()
        let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var out = ContactsProbeOutput(pid: pid, frontmostSet: false, steps: [], reached: false, cards: [])
        out.steps.append(scan(window: window, step: 0, key: "none", redact: redact))
        if scanOnly {
            if let dump { _ = try ProbeTreeSummary.dump(app: app, to: dump, raw: options.noRedact) }
            print(options.json ? try ProbeSession.encode(out) : out.render()); return
        }
        if (try? app.isSettable(AXAttribute.frontmost)) == true {
            try app.setAttribute(AXAttribute.frontmost, to: .bool(true)); out.frontmostSet = true
            for _ in 0..<15 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { Thread.sleep(forTimeInterval: 0.1) }
        }
        try KeystrokeInjector.postShortcut(.commandDigit(8), toPid: pid)
        Thread.sleep(forTimeInterval: settle)
        var last = scan(window: window, step: 1, key: "⌘8", redact: redact)
        out.steps.append(last)
        var n = 1
        while !last.showing, n <= steps {
            let move = WeComActions.moveFocusOffTextInput(app: app, window: window)
            print("focus \(move.summary) before ⌃Tab \(n)")
            try KeystrokeInjector.postShortcut(.controlTab, toPid: pid)
            Thread.sleep(forTimeInterval: settle)
            n += 1
            last = scan(window: window, step: n, key: "⌃Tab", redact: redact)
            out.steps.append(last)
        }
        out.reached = last.showing
        if out.reached {
            try WeComContactsView.selectNewCustomers(window: window)
            Thread.sleep(forTimeInterval: settle)
            if let table = try WeComContactsView.newCustomersTable(window: window) {
                let cards = try NewCustomersPage.parse(table: table)
                out.cards = cards.map { "\($0.status.rawValue) \($0.source) \(redact($0.name) ?? "-")" }
                if let accept {
                    guard let card = cards.first(where: { $0.name == accept }) else { throw ValidationError("no card named \(accept)") }
                    if card.status == .pending { try card.button.perform(AXAction.press) }
                    Thread.sleep(forTimeInterval: settle)
                    let node = try ProbeTreeSummary.dump(app: app, to: dump, raw: options.noRedact)
                    out.overlays = ProbeTreeSummary.overlays(node)
                    let done = app.descendants(maxDepth: 14, maxNodes: 6000).first { (try? $0.role()) == AXRole.button && (try? $0.title()) == "完成" }
                    out.finishButton = done.map(ProbeTreeSummary.path(of:))
                    if finish, let done {
                        try done.perform(AXAction.press)
                        Thread.sleep(forTimeInterval: settle)
                        out.acceptStatus = try NewCustomersPage.parse(table: table).first { $0.name == accept }?.status.rawValue ?? "gone"
                    }
                }
            }
        }
        if accept == nil, let dump { _ = try ProbeTreeSummary.dump(app: app, to: dump, raw: options.noRedact) }
        if !noReturn {
            let opened = NSWorkspace.shared.open(WeComActions.conversationListDeepLink)
            Thread.sleep(forTimeInterval: settle)
            out.returned = opened && !WeComContactsView.isShowing(window: window)
            if let previous, previous != pid { NSRunningApplication(processIdentifier: previous)?.activate() }
        }
        print(options.json ? try ProbeSession.encode(out) : out.render())
    }
}
