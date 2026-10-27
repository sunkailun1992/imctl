import AXKit
import Foundation
import Testing
@testable import imctld

@Suite("AX timing reporter")
struct AXTimingReporterTests {
    private final class Box {
        var nowMs: Int64 = 0
        var lines: [String] = []
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ax-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func reporter(_ box: Box, reportURL: URL) -> (AXTimingReporter, AXCallTimings) {
        let timings = AXCallTimings(wallMs: { box.nowMs })
        let reporter = AXTimingReporter(timings: timings, reportURL: reportURL, log: { box.lines.append($0) }, nowMs: { box.nowMs })
        return (reporter, timings)
    }

    private static func slow(_ name: String = AXAttribute.children, ms: Double = 6012, outcome: String = "cannotComplete") -> AXCallSample {
        AXCallSample(atMs: 0, operation: .get, name: name, nanos: UInt64(ms * 1_000_000), outcome: outcome, thread: "main")
    }

    @Test func slowLineCarriesOnlyNamesAndNumbers() {
        #expect(AXTimingReporter.slowLine(Self.slow()) == "ax: slow get AXChildren 6012 ms cannotComplete on main")
    }

    @Test func slowLinesAreRateLimited() throws {
        let box = Box()
        let (reporter, _) = Self.reporter(box, reportURL: try Self.temporaryDirectory().appendingPathComponent("ax-timings.json"))
        for _ in 0..<35 { reporter.noteSlowCall(Self.slow()) }
        #expect(box.lines.filter { $0.hasPrefix("ax: slow") }.count == 30)
        box.nowMs = 300_000
        reporter.tick()
        let summary = try #require(box.lines.last)
        #expect(summary.hasPrefix("ax: summary") && summary.contains("suppressed=5"))
        reporter.noteSlowCall(Self.slow())
        #expect(box.lines.last?.hasPrefix("ax: slow") == true)
        box.nowMs = 600_000
        reporter.tick()
        #expect(box.lines.last?.contains("suppressed=0") == true)
    }

    @Test func tickWritesTheReportEvery30sAndTheSummaryEvery300s() throws {
        let box = Box()
        let url = try Self.temporaryDirectory().appendingPathComponent("ax-timings.json")
        let (reporter, timings) = Self.reporter(box, reportURL: url)
        var writes: [Int64] = []
        for second: Int64 in [0, 29, 30, 299, 300] {
            box.nowMs = second * 1000
            timings.record(Self.slow(ms: 1, outcome: "ok"))
            reporter.tick()
            let report = try JSONDecoder().decode(AXCallTimingReport.self, from: Data(contentsOf: url))
            if writes.last != report.generatedMs { writes.append(report.generatedMs) }
        }
        #expect(writes == [0, 30_000, 299_000])
        #expect(box.lines.filter { $0.hasPrefix("ax: summary") }.count == 1)
    }

    @Test func reportFileIsOwnerOnlyAndDecodes() throws {
        let box = Box()
        let url = try Self.temporaryDirectory().appendingPathComponent("ax-timings.json")
        let (reporter, timings) = Self.reporter(box, reportURL: url)
        timings.record(Self.slow())
        try reporter.writeReport()
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600)
        let report = try JSONDecoder().decode(AXCallTimingReport.self, from: Data(contentsOf: url))
        #expect(report.calls == 1 && report.timeouts == 1)
    }

    @Test func unwritableReportDoesNotThrow() throws {
        let box = Box()
        let blocker = try Self.temporaryDirectory().appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let (reporter, _) = Self.reporter(box, reportURL: blocker.appendingPathComponent("ax-timings.json"))
        reporter.tick()
        box.nowMs = 30_000
        reporter.tick()
        #expect(box.lines.filter { $0.hasPrefix("ax: report not written") }.count == 1)
    }

    @Test func outputsCarryNoContent() throws {
        let box = Box()
        let url = try Self.temporaryDirectory().appendingPathComponent("ax-timings.json")
        let (reporter, timings) = Self.reporter(box, reportURL: url)
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, title: "机密测试群", value: .string("私人消息正文")))
        fake.batchesReads = true
        let measured = MeasuredAXBackend(base: fake, timings: timings)
        measured.slowCallThresholdMs = 0
        measured.onSlowCall = reporter.noteSlowCall
        let root = AXElement(handle: fake.rootHandle, backend: measured)
        _ = try root.title()
        _ = try root.read([AXAttribute.title, AXAttribute.value]).valueString()
        try reporter.writeReport()
        box.nowMs = 300_000
        reporter.tick()
        let text = box.lines.joined(separator: "\n") + String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!text.contains("机密") && !text.contains("私人"))
        #expect(text.contains("AXTitle"))
    }

    @Test func batchFallbacksAreReportedWhenKnown() throws {
        let box = Box()
        let (reporter, timings) = Self.reporter(box, reportURL: try Self.temporaryDirectory().appendingPathComponent("ax-timings.json"))
        #expect(reporter.stateSummary()["batchFallbacks"] == nil)
        #expect(!AXTimingReporter.summaryLine(timings.report(), suppressedSlowLines: 0, batchFallbacks: nil).contains("fallbacks="))
        reporter.batchFallbacks = { 3 }
        #expect(reporter.stateSummary()["batchFallbacks"] as? Int == 3)
        box.nowMs = 300_000
        reporter.tick()
        #expect(box.lines.last?.contains("fallbacks=3") == true)
    }

    @Test func stateSummaryHasPollPercentiles() throws {
        let box = Box()
        let (reporter, timings) = Self.reporter(box, reportURL: try Self.temporaryDirectory().appendingPathComponent("ax-timings.json"))
        timings.record(Self.slow())
        for ms in [100.0, 200, 7000] { timings.recordScope(AXTimingReporter.pollScope, nanos: UInt64(ms * 1_000_000), ok: true) }
        let summary = reporter.stateSummary()
        #expect(summary["calls"] as? Int == 1)
        #expect(summary["timeouts"] as? Int == 1)
        #expect(summary["polls"] as? Int == 3)
        #expect(summary["pollP50Ms"] as? Double == 200)
        #expect(summary["pollMaxMs"] as? Double == 7000)
        #expect(JSONSerialization.isValidJSONObject(summary))
    }
}
