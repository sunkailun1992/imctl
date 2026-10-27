import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import WeComAdapter

/// B61: the batched parsing paths must give exactly what one-attribute-at-a-time
/// reads give, on every recorded client tree.
@Suite("Batched reads parse like single reads")
struct BatchReadEquivalenceTests {
    static let fixtureNames: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: Fixtures.root.path)) ?? [])
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".raw.json") }
        .sorted()

    /// Everything the four paths produce, minus how many round trips it took.
    struct Parsed: Equatable {
        var windowError: String?
        var layoutError: String?
        var windowFrame: CGRect?
        var conversationTable: AXElementHandle?
        var conversationTableFrame: CGRect?
        var messageTable: AXElementHandle?
        var messageTableFrame: CGRect?
        var messageScrollArea: AXElementHandle?
        var composer: AXElementHandle?
        var composerFrame: CGRect?
        var composerAmbiguous: Bool?
        var activeTitle: AXElementHandle?
        var searchField: AXElementHandle?
        var plusButton: AXElementHandle?
        var messageImages: [CGRect]?
        var conversations: [ConversationRow]?
        var conversationError: String?
        var messages: [MessageRow]?
        var messageError: String?
    }

    static func parse(_ fake: FakeAXBackend, batchReads: Bool) -> (parsed: Parsed, calls: Int) {
        fake.batchesReads = batchReads
        let timings = AXCallTimings()
        let backend = MeasuredAXBackend(base: fake, timings: timings, batchReads: batchReads)
        let root = AXElement(handle: fake.rootHandle, backend: backend)
        var parsed = Parsed()
        // A table-rooted recording (the 5.0.11 file / video rows) is a message table on its own.
        if (try? root.role()) == AXRole.table {
            let frame = (try? root.frame()) ?? .zero
            do { parsed.messages = try MessageRowParser().parse(table: root, tableFrame: frame) }
            catch { parsed.messageError = "\(error)" }
            return (parsed, timings.report().calls)
        }
        let window: AXElement
        do { window = try WeComWindowLocator.mainWindow(from: root) } catch {
            parsed.windowError = "\(error)"
            return (parsed, timings.report().calls)
        }
        let layout: WeComLayout
        do { layout = try WeComLayout.locate(in: window) } catch {
            parsed.layoutError = "\(error)"
            return (parsed, timings.report().calls)
        }
        parsed.windowFrame = layout.windowFrame
        parsed.conversationTable = layout.conversationTable.handle
        parsed.conversationTableFrame = layout.conversationTableFrame
        parsed.messageTable = layout.messageTable?.handle
        parsed.messageTableFrame = layout.messageTableFrame
        parsed.messageScrollArea = layout.messageScrollArea?.handle
        parsed.composer = layout.composer?.handle
        parsed.composerFrame = layout.composerFrame
        parsed.composerAmbiguous = layout.composerAmbiguous
        parsed.activeTitle = layout.activeTitle?.handle
        parsed.searchField = layout.searchField?.handle
        parsed.plusButton = layout.plusButton?.handle
        parsed.messageImages = layout.messageImages
        do { parsed.conversations = try ConversationRowParser().parse(table: layout.conversationTable) }
        catch { parsed.conversationError = "\(error)" }
        if let table = layout.messageTable, let frame = layout.messageTableFrame {
            do { parsed.messages = try MessageRowParser().parse(table: table, tableFrame: frame, images: layout.messageImages) }
            catch { parsed.messageError = "\(error)" }
        }
        return (parsed, timings.report().calls)
    }

    static func load(_ name: String) throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent(name)))
    }

    @Test func fixturesArePresent() {
        #expect(Self.fixtureNames.count >= 14)
        #expect(Self.fixtureNames.contains("wecom-5.0.11-main-window.json"))
    }

    @Test(arguments: fixtureNames)
    func everyFixtureParsesTheSameBothWays(name: String) throws {
        let fake = try Self.load(name)
        let single = Self.parse(fake, batchReads: false)
        let batched = Self.parse(fake, batchReads: true)
        #expect(batched.parsed == single.parsed, "\(name)")
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test(arguments: ["wecom-5.0.10-main-window.json", "wecom-5.0.11-main-window.json", "wecom-5.0.11-external-group.json"])
    func batchUsesFewerRoundTrips(name: String) throws {
        let fake = try Self.load(name)
        let single = Self.parse(fake, batchReads: false)
        let batched = Self.parse(fake, batchReads: true)
        #expect(!(single.parsed.conversations ?? []).isEmpty, "\(name) has conversation rows")
        // Single reads only fetch what the parsers use (the pre-B61 behaviour); recorded
        // trees still need at least 30% fewer round trips batched (41–48% on 2026-10-27).
        #expect(batched.calls * 10 < single.calls * 7, "\(name): batched \(batched.calls) vs single \(single.calls)")
    }

    /// 2026-09-23 the walk stopped reading frames of unrelated roles to save synchronous
    /// calls; batched, geometry rides in the round trip that reads the role.
    @Test func batchedLayoutWalkNeverReadsGeometryOnItsOwn() throws {
        let fake = try Self.load("wecom-5.0.10-main-window.json")
        fake.batchesReads = true
        let timings = AXCallTimings()
        let measured = MeasuredAXBackend(base: fake, timings: timings)
        let window = try WeComWindowLocator.mainWindow(from: AXElement(handle: fake.rootHandle, backend: measured))
        timings.reset()
        let layout = try WeComLayout.locate(in: window)
        let geometry: Set<String> = [AXAttribute.frame, AXAttribute.position, AXAttribute.size]
        let singles = timings.report(topOperations: 1000).operations.filter { $0.operation == AXCallOperation.get.rawValue && geometry.contains($0.name) }
        // Only the message scroll area's own frame is read after the walk (up to three
        // times); single reads paid 53 geometry calls on this tree.
        #expect(singles.reduce(0) { $0 + $1.count } <= 3)
        #expect((layout.messageTableFrame?.width ?? 0) > 1000)
    }

    @Test func batchedMessageRowCostsOneRoundTripPerElement() throws {
        let tableFrame = CGRect(x: 0, y: 0, width: 600, height: 200)
        let fake = FakeAXBackend(root: AXNode(role: AXRole.table, frame: tableFrame, children: [
            AXNode(role: AXRole.row, frame: CGRect(x: 0, y: 0, width: 600, height: 80), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 0, y: 0, width: 600, height: 80), children: [
                    AXNode(role: AXRole.group, frame: CGRect(x: 10, y: 10, width: 40, height: 40)),
                    AXNode(role: AXRole.textArea, value: .string("hello"), frame: CGRect(x: 400, y: 20, width: 100, height: 20)),
                ]),
            ]),
        ]))
        fake.batchesReads = true
        let timings = AXCallTimings()
        let measured = MeasuredAXBackend(base: fake, timings: timings)
        let rows = try MessageRowParser().parse(table: AXElement(handle: fake.rootHandle, backend: measured), tableFrame: tableFrame)
        #expect(rows.count == 1 && rows[0].text == "hello" && rows[0].kind == .message)
        // the table's children, then one batch each for the row, the cell and its two children
        let report = timings.report()
        #expect(report.calls == 5)
        #expect(report.operations.filter { $0.operation == AXCallOperation.getMany.rawValue }.reduce(0) { $0 + $1.count } == 4)
    }

    @Test func messageRowsUseFewerRoundTrips() throws {
        let fake = try Self.load("wecom-5.0.11-file-video-rows.json")
        let single = Self.parse(fake, batchReads: false)
        let batched = Self.parse(fake, batchReads: true)
        #expect((single.parsed.messages ?? []).count >= 5)
        #expect(batched.calls * 2 < single.calls, "batched \(batched.calls) vs single \(single.calls)")
    }
}
