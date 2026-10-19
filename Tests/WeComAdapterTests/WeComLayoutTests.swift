import CoreGraphics
import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("WeComLayout on 5.0.10 fixture")
struct WeComLayoutTests {
    @Test func locatesFiveRegionsByGeometry() throws {
        let fake = try Fixtures.mainWindow()
        let window = try WeComWindowLocator.mainWindow(from: fake.rootElement)
        let layout = try WeComLayout.locate(in: window)
        #expect(layout.windowFrame.width == 1920)
        #expect(layout.conversationTableFrame.minX < 100 && layout.conversationTableFrame.width < 400)
        #expect((layout.messageTableFrame?.width ?? 0) > 1000)
        #expect(try layout.composer?.identifier() == "_NS:30")
        #expect(try layout.composer?.isSettable(AXAttribute.value) == true)
        #expect(try layout.activeTitle?.valueString() == "文件传输助手")
        #expect(try layout.searchField?.role() == AXRole.textField)
    }

    @Test func skipsFrameReadsForUnrelatedRoles() throws {
        let fake = try Fixtures.mainWindow()
        let window = try WeComWindowLocator.mainWindow(from: fake.rootElement)
        let unrelatedRoles: Set<String> = [AXRole.group, AXRole.row, AXRole.cell, AXRole.scrollBar]
        let unrelatedHandles = Set(window.descendants().filter {
            unrelatedRoles.contains((try? $0.role()) ?? "")
        }.map(\.handle))
        #expect(!unrelatedHandles.isEmpty)

        var frameReads = Set<AXElementHandle>()
        fake.onRead = { handle, attribute in
            if attribute == AXAttribute.frame { frameReads.insert(handle) }
        }
        let layout = try WeComLayout.locate(in: window)
        fake.onRead = nil

        #expect(unrelatedHandles.isDisjoint(with: frameReads))
        #expect(layout.conversationTableFrame.width > 0)
        #expect((layout.messageTableFrame?.width ?? 0) > 1000)
        #expect(try layout.activeTitle?.valueString() == "文件传输助手")
    }

    @Test func locatingTheShellDoesNotWalkConversationOrMessageRows() throws {
        let fake = try Fixtures.mainWindow()
        let window = try WeComWindowLocator.mainWindow(from: fake.rootElement)
        let conversationTable = try #require(fake.handle(atPath: [0, 33, 2, 0]))
        let messageTable = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        var tableChildrenReads = 0
        fake.onRead = { handle, attribute in
            if attribute == AXAttribute.children && (handle == conversationTable || handle == messageTable) {
                tableChildrenReads += 1
            }
        }
        let layout = try WeComLayout.locate(in: window)
        fake.onRead = nil
        #expect(tableChildrenReads == 0)
        #expect(layout.conversationTable.handle == conversationTable && layout.messageTable?.handle == messageTable)
    }

    @Test func titleSurvivesAScrolledMessageTable() throws {
        // 13+ rows loaded: WeCom reports the table frame at y < 0 (scrolled to the bottom).
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        fake.mutate(table, attribute: AXAttribute.frame, to: .rect(CGRect(x: 310, y: -5, width: 1611, height: 1001)))
        // a time label of a row scrolled above the viewport now sits above the header
        let timeLabel = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0, 0, 0, 0]))
        fake.mutate(timeLabel, attribute: AXAttribute.frame, to: .rect(CGRect(x: 1102, y: 2, width: 26.5, height: 18)))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(try layout.activeTitle?.valueString() == "文件传输助手")
        #expect(try WeComReader(window: fake.rootElement).activeConversationTitle() == "文件传输助手")
    }

    @Test func layoutExposesMessageScrollArea() throws {
        let fake = try Fixtures.mainWindow()
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(try layout.messageScrollArea?.role() == AXRole.scrollArea)
        #expect(try layout.messageScrollArea?.actions().contains(AXAction.scrollUpByPage) == true)
        #expect(try layout.messageScrollArea?.children().filter { try $0.role() == AXRole.scrollBar }.count == 2)
        let noActive = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-main-window.json")))
        let l2 = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: noActive.rootElement))
        #expect(l2.messageTable == nil && l2.messageScrollArea == nil)
    }

    /// Live 2026-09-15 21:19 (5.0.11): an external group's header title is an
    /// editable AXTextField (y 20); the static text below it (y 44) is the
    /// "由企业微信用户创建的外部群…" banner, which used to be read as the title.
    @Test func groupTitleTextFieldWinsOverTheBannerBelowIt() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        let title = try #require(layout.activeTitle)
        #expect(try title.role() == AXRole.textField && (try title.frame())?.minY == 20)
        #expect((try layout.searchField?.frame())?.minX ?? 999 < layout.conversationTableFrame.maxX)   // the search box stays the left one
        let header = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        #expect(header.raw == (try title.valueString()) && header.memberCount == nil)
    }

    @Test func missingTableIsReportedAsRegionError() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(throws: WeComError.region("conversationTable")) { try WeComLayout.locate(in: fake.rootElement) }
    }

    @Test func locatorRejectsNonWindowRoots() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.button))
        #expect(throws: WeComError.noWindow) { try WeComWindowLocator.mainWindow(from: fake.rootElement) }
    }

    @Test func filterSidePanelDoesNotShadowTheConversationList() throws {
        // 2026-09-15, 5.0.11: the 会话筛选 side panel is a 242 px tall AXTable left of the conversation list.
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-filter-panel.json")))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(Int(layout.conversationTableFrame.minX) == 159 && Int(layout.conversationTableFrame.height) == 1138)
        #expect((layout.messageTableFrame?.width ?? 0) > 1000)
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.activeConversationTitle() == "文件传输助手")
        let rows = try reader.conversations()
        #expect(rows.count == 11 && rows.allSatisfy { $0.frame.height == 64 })
        #expect(rows.contains { $0.title == "文件传输助手" && $0.selected })
    }

    @Test func shortMessageTableIsStillTheMessageTable() throws {
        // Few messages loaded: the message table is short; only the conversation table must be tall.
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        fake.mutate(table, attribute: AXAttribute.frame, to: .rect(CGRect(x: 310, y: 63, width: 1611, height: 150)))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(Int(layout.messageTableFrame?.height ?? 0) == 150 && Int(layout.conversationTableFrame.minX) == 59)
    }
}
