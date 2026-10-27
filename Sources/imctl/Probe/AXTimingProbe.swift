import AXKit
import Foundation
import WeComAdapter

/// B61: reads one client both ways, one AX attribute at a time on access (the
/// pre-batching pattern) and batched, and reports timings, round trips and whether
/// the two parses agree. Read-only; the report holds numbers and fixed labels only.
struct AXTimingProbe {
    struct ModeResult: Equatable, Codable {
        var mode: String
        var locateMs: [Double] = []
        var conversationsMs: [Double] = []
        var messagesMs: [Double] = []
        var calls = 0
        var axMs = 0.0
        var timeouts = 0
        /// Batched reads that came back empty (the client could not batch).
        var fallbacks = 0
    }

    struct Result: Equatable, Codable {
        var rounds: Int
        var messageTable: Bool
        var single: ModeResult
        var batch: ModeResult
        var conversationsEqual: Bool
        var conversationDiffs: Int
        var messagesEqual: Bool
        var messageDiffs: Int
        /// Rows that changed between the two single passes of a round: the client
        /// itself changing (a new message, a badge), not the read paths disagreeing.
        var conversationNoise = 0
        var messageNoise = 0
    }

    private struct Pass {
        var conversations: [ConversationRow]
        var messages: [MessageRow]?
    }

    /// Each round reads single, batched, then single again through fresh timing
    /// backends over `base`. A batched row counts as a diff only when it disagrees
    /// with both single passes; the second single pass is not timed.
    static func run(rounds: Int, base: AXBackend, root: (AXBackend) throws -> AXElement,
                    now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws -> Result {
        var single = ModeResult(mode: "single")
        var batch = ModeResult(mode: "batch")
        var check = ModeResult(mode: "check")
        var result = Result(rounds: rounds, messageTable: false, single: single, batch: batch,
                            conversationsEqual: true, conversationDiffs: 0, messagesEqual: true, messageDiffs: 0)
        for _ in 0..<rounds {
            let before = try pass(batchReads: false, base: base, root: root, now: now, into: &single)
            let batched = try pass(batchReads: true, base: base, root: root, now: now, into: &batch)
            let after = try pass(batchReads: false, base: base, root: root, now: now, into: &check)
            result.conversationDiffs += min(diffCount(before.conversations, batched.conversations),
                                            diffCount(after.conversations, batched.conversations))
            result.conversationNoise += diffCount(before.conversations, after.conversations)
            result.messageDiffs += min(messageDiff(before.messages, batched.messages), messageDiff(after.messages, batched.messages))
            result.messageNoise += messageDiff(before.messages, after.messages)
            result.messageTable = result.messageTable || before.messages != nil
        }
        result.single = single
        result.batch = batch
        result.conversationsEqual = result.conversationDiffs == 0
        result.messagesEqual = result.messageDiffs == 0
        return result
    }

    /// A pane that has a message table in one pass and none in the other counts as one diff.
    private static func messageDiff(_ lhs: [MessageRow]?, _ rhs: [MessageRow]?) -> Int {
        diffCount(lhs ?? [], rhs ?? []) + ((lhs == nil) == (rhs == nil) ? 0 : 1)
    }

    private static func pass(batchReads: Bool, base: AXBackend, root: (AXBackend) throws -> AXElement,
                             now: @escaping () -> UInt64, into mode: inout ModeResult) throws -> Pass {
        let timings = AXCallTimings()
        let measured = MeasuredAXBackend(base: base, timings: timings, batchReads: batchReads, now: now)
        let window = try WeComWindowLocator.mainWindow(from: try root(measured))
        var started = now()
        let layout = try WeComLayout.locate(in: window)
        mode.locateMs.append(milliseconds(since: started, now))
        started = now()
        let conversations = try ConversationRowParser().parse(table: layout.conversationTable)
        mode.conversationsMs.append(milliseconds(since: started, now))
        var messages: [MessageRow]?
        if let table = layout.messageTable, let frame = layout.messageTableFrame {
            started = now()
            messages = try MessageRowParser().parse(table: table, tableFrame: frame, images: layout.messageImages)
            mode.messagesMs.append(milliseconds(since: started, now))
        }
        let report = timings.report(topOperations: .max)
        mode.calls += report.calls
        mode.axMs += report.totalMs
        mode.timeouts += report.timeouts
        mode.fallbacks += report.operations.reduce(0) { $0 + ($1.outcomes["fallback"] ?? 0) }
        return Pass(conversations: conversations, messages: messages)
    }

    /// Rows that differ in anything but their AX handle, plus the difference in row count.
    static func diffCount(_ lhs: [ConversationRow], _ rhs: [ConversationRow]) -> Int {
        let placeholder = AXElementHandle(id: 0)
        let strip: (ConversationRow) -> ConversationRow = { var row = $0; row.handle = placeholder; return row }
        return zip(lhs.map(strip), rhs.map(strip)).filter { $0 != $1 }.count + abs(lhs.count - rhs.count)
    }

    static func diffCount(_ lhs: [MessageRow], _ rhs: [MessageRow]) -> Int {
        let placeholder = AXElementHandle(id: 0)
        let strip: (MessageRow) -> MessageRow = { var row = $0; row.handle = placeholder; return row }
        return zip(lhs.map(strip), rhs.map(strip)).filter { $0 != $1 }.count + abs(lhs.count - rhs.count)
    }

    static func render(_ result: Result) -> String {
        func line(_ mode: ModeResult) -> String {
            var parts = ["locate \(spread(mode.locateMs))", "conversations \(spread(mode.conversationsMs))"]
            if !mode.messagesMs.isEmpty { parts.append("messages \(spread(mode.messagesMs))") }
            return "\(mode.mode): " + parts.joined(separator: ", ")
                + "; \(mode.calls) AX calls, \(format(mode.axMs)) ms in AX, \(mode.timeouts) timeouts, \(mode.fallbacks) fallbacks"
        }
        return [
            "AX timing probe: \(result.rounds) round(s) per mode, message table: \(result.messageTable ? "yes" : "no")",
            line(result.single),
            line(result.batch),
            "parse equal: conversations \(result.conversationsEqual) (\(result.conversationDiffs) diffs, \(result.conversationNoise) changed between single passes),"
                + " messages \(result.messagesEqual) (\(result.messageDiffs) diffs, \(result.messageNoise) changed between single passes)",
        ].joined(separator: "\n")
    }

    /// Median and maximum, in milliseconds.
    private static func spread(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        return "\(format(sorted[(sorted.count - 1) / 2]))/\(format(sorted[sorted.count - 1])) ms"
    }

    private static func milliseconds(since start: UInt64, _ now: () -> UInt64) -> Double {
        let end = now()
        return end >= start ? (Double(end - start) / 100_000).rounded() / 10 : 0
    }

    private static func format(_ ms: Double) -> String { String(format: "%.1f", ms) }
}
