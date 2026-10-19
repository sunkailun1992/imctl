import Foundation
import Testing
@testable import imctl_console

@Suite("Docs page support")
struct DocsTests {
    @Test func stylerSplitsHeadingsCodeTablesBulletsAndParagraphs() {
        let md = """
        # 标题
        第一段第一行
        第一段第二行

        ## 二级
        - 要点一
        1. 第一步
        ```json
        {"a": 1}
        ```
        | 列 | 值 |
        |---|---|
        | x | `1` |
        尾段
        """
        let blocks = MarkdownStyler.blocks(md)
        #expect(blocks.map(\.kind) == [.heading(1), .paragraph, .heading(2), .bullet, .bullet, .code, .table, .paragraph])
        #expect(blocks[1].text == "第一段第一行 第一段第二行" && blocks[3].text == "要点一" && blocks[4].text == "1. 第一步")
        #expect(blocks[5].text == "{\"a\": 1}" && blocks[6].text == "列  │  值\nx  │  `1`" && blocks[7].text == "尾段")
    }

    @Test func locatorPrefersTheEnvironmentThenTheBundleThenTheRepo() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "# x".write(to: tmp.appendingPathComponent(DocsLocator.files[0]), atomically: true, encoding: .utf8)
        #expect(DocsLocator.directory(environment: ["IMCTL_DOCS_DIR": tmp.path], resources: nil, executable: nil) == tmp)
        // a development binary under <repo>/.build/… finds the repo's docs/protocol by walking up
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fakeExecutable = repo.appendingPathComponent(".build/arm64-apple-macosx/debug/imctl-console")
        #expect(DocsLocator.directory(environment: [:], resources: nil, executable: fakeExecutable)?.lastPathComponent == "protocol")
        #expect(DocsLocator.directory(environment: [:], resources: nil, executable: nil) == nil)
        #expect(DocsLocator.titles.count == DocsLocator.files.count)
    }
}
