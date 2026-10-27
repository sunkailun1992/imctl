import AXKit
import ControlCore
import Foundation

/// B61: the daemon's local output of AX call timings: a compact summary for
/// `state.json`, the full report in `ax-timings.json` (0600, every 30 s), one
/// rate-limited log line per slow call and a summary line every 5 minutes.
/// Everything written carries AX names, counts, milliseconds, outcome labels
/// and queue labels only.
final class AXTimingReporter {
    /// The scope `DaemonWatcher` records around each watcher poll.
    static let pollScope = "watch.poll"
    static let slowLinesPerMinute = 30
    static let reportIntervalMs: Int64 = 30_000
    static let summaryIntervalMs: Int64 = 300_000

    let timings: AXCallTimings
    /// Live batched reads that came back empty (WeCom could not batch); nil when unknown.
    var batchFallbacks: (() -> Int)?
    private let reportURL: URL
    private let log: (String) -> Void
    private let nowMs: () -> Int64
    private let lock = NSLock()
    private var minuteStartMs: Int64?
    private var slowLinesThisMinute = 0
    private var suppressedSlowLines = 0
    private var lastReportMs: Int64?
    private var lastSummaryMs: Int64
    private var lastWriteProblem: String?

    init(timings: AXCallTimings, reportURL: URL, log: @escaping (String) -> Void, nowMs: @escaping () -> Int64 = Clock.nowMs) {
        self.timings = timings
        self.reportURL = reportURL
        self.log = log
        self.nowMs = nowMs
        lastSummaryMs = nowMs()
    }

    /// `MeasuredAXBackend.onSlowCall`; may run on any queue.
    func noteSlowCall(_ sample: AXCallSample) {
        let now = nowMs()
        lock.lock()
        if minuteStartMs.map({ now - $0 >= 60_000 }) ?? true {
            minuteStartMs = now
            slowLinesThisMinute = 0
        }
        let write = slowLinesThisMinute < Self.slowLinesPerMinute
        if write { slowLinesThisMinute += 1 } else { suppressedSlowLines += 1 }
        lock.unlock()
        if write { log(Self.slowLine(sample)) }
    }

    /// The `ax` entry of `state.json`.
    func stateSummary() -> [String: Any] {
        let report = timings.report(topOperations: 0)
        let poll = report.scopes.first { $0.name == Self.pollScope }
        var summary: [String: Any] = [
            "calls": report.calls, "totalMs": report.totalMs, "timeouts": report.timeouts, "slowCalls": report.slowCalls,
            "polls": poll?.count ?? 0, "pollP50Ms": poll?.p50Ms ?? 0, "pollP95Ms": poll?.p95Ms ?? 0, "pollMaxMs": poll?.maxMs ?? 0,
        ]
        if let batchFallbacks { summary["batchFallbacks"] = batchFallbacks() }
        return summary
    }

    /// Called with every state write (every 5 s); writes the report and the summary when due.
    func tick() {
        let now = nowMs()
        lock.lock()
        let reportDue = lastReportMs.map { now - $0 >= Self.reportIntervalMs } ?? true
        if reportDue { lastReportMs = now }
        let summaryDue = now - lastSummaryMs >= Self.summaryIntervalMs
        var suppressed = 0
        if summaryDue {
            lastSummaryMs = now
            suppressed = suppressedSlowLines
            suppressedSlowLines = 0
        }
        lock.unlock()
        if reportDue {
            do {
                try writeReport()
                lastWriteProblem = nil
            } catch {
                let problem = (error as NSError).localizedDescription
                if problem != lastWriteProblem { log("ax: report not written (\(problem))") }
                lastWriteProblem = problem
            }
        }
        if summaryDue { log(Self.summaryLine(timings.report(), suppressedSlowLines: suppressed, batchFallbacks: batchFallbacks?())) }
    }

    func writeReport() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(timings.report())
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
    }

    static func slowLine(_ sample: AXCallSample) -> String {
        let what = sample.name.isEmpty ? sample.operation.rawValue : "\(sample.operation.rawValue) \(sample.name)"
        return "ax: slow \(what) \(Int((Double(sample.nanos) / 1_000_000).rounded())) ms \(sample.outcome) on \(sample.thread)"
    }

    static func summaryLine(_ report: AXCallTimingReport, suppressedSlowLines: Int, batchFallbacks: Int? = nil) -> String {
        var line = "ax: summary calls=\(report.calls) ms=\(format(report.totalMs)) timeouts=\(report.timeouts)"
            + " slow=\(report.slowCalls) suppressed=\(suppressedSlowLines)"
        if let batchFallbacks { line += " fallbacks=\(batchFallbacks)" }
        if let poll = report.scopes.first(where: { $0.name == pollScope }) {
            line += " poll n=\(poll.count) p50=\(format(poll.p50Ms)) p95=\(format(poll.p95Ms)) max=\(format(poll.maxMs)) failed=\(poll.failures)"
        }
        let top = report.operations.prefix(5).map { op in
            "\(op.operation) \(op.name) n=\(op.count) p95=\(format(op.p95Ms)) max=\(format(op.maxMs))"
        }
        if !top.isEmpty { line += "; top: " + top.joined(separator: "; ") }
        return line
    }

    private static func format(_ ms: Double) -> String {
        ms == ms.rounded() ? String(Int(ms)) : String(format: "%.1f", ms)
    }
}
