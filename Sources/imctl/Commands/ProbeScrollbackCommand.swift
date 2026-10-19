import ArgumentParser
import AXKit
import ControlCore
import Foundation
import WeComAdapter

extension ScrollbackStrategy: ExpressibleByArgument {}

struct ScrollbackReport: Codable {
    var active: String?
    var strategy: String
    var barsBefore: [Double]
    var barsAfter: [Double]
    var outcome: ScrollbackOutcome
    var firstText: String?
    var lastText: String?
    var elapsedMs: Int
}

struct ProbeScrollbackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrollback",
        abstract: "Scroll the message area up (AXScrollBar.AXValue / AXScrollUpByPage) so the client loads older history; report row counts and bar values. Active conversation must be allowlisted."
    )

    @OptionGroup var options: ProbeOptions
    @Flag(name: .customLong("allow-scroll"), help: "Required: enables the scrollHistory action on the active (allowlisted) conversation.") var allowScroll = false
    @Option(name: .customLong("min-rows"), help: "Stop once this many rows are loaded.") var minRows: Int = 40
    @Option(name: .customLong("max-scrolls")) var maxScrolls: Int = 20
    @Option(help: "auto | bar | page") var strategy: ScrollbackStrategy = .auto
    @Option(name: .customLong("verify-timeout"), help: "Seconds to wait for rows to grow after each scroll.") var verifyTimeout: Double = 1.5
    @Flag(name: .customLong("no-restore"), help: "Leave the view scrolled up (diagnostics).") var noRestore = false

    func collect() throws -> ScrollbackReport {
        let reader = try ProbeSession.reader(options)
        let redact = ProbeSession.redactor(options)
        var actions = WeComActions(policy: ProbePolicy.make(enabled: allowScroll ? [.scrollHistory] : []))
        actions.verifyTimeout = verifyTimeout
        let started = Date()
        let before = try barValues(reader)
        let outcome = try actions.loadOlderMessages(reader: reader, minRows: minRows, maxScrolls: maxScrolls, strategy: strategy, restore: !noRestore)
        let after = try barValues(reader)
        let messages = try reader.messages()
        return ScrollbackReport(
            active: redact(try reader.activeConversationTitle()), strategy: strategy.rawValue, barsBefore: before, barsAfter: after,
            outcome: outcome, firstText: redact(messages.first?.text), lastText: redact(messages.last?.text),
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private func barValues(_ reader: WeComReader) throws -> [Double] {
        guard let area = reader.layout.messageScrollArea else { return [] }
        return try area.children().filter { try $0.role() == AXRole.scrollBar }.map { (try $0.value()?.doubleValue) ?? -1 }
    }

    func run() throws {
        let out = try collect()
        if options.json {
            print(try ProbeSession.encode(out))
        } else {
            print("active: \(out.active ?? "-") strategy=\(out.strategy)")
            print("rows: \(out.outcome.rowsBefore) -> \(out.outcome.rowsAfter) scrolls=\(out.outcome.scrolls) restored=\(out.outcome.restored) elapsed=\(out.elapsedMs)ms")
            print("bars: \(out.barsBefore) -> \(out.barsAfter)")
            print("first: \(out.firstText ?? "-")")
            print("last:  \(out.lastText ?? "-")")
        }
    }
}
