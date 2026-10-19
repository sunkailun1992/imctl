import Foundation
import Testing
@testable import AXKit
@testable import imctl

@Suite("dump-tree pipeline")
struct DumpTreeCommandTests {
    func fixtureURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tree = AXNode(role: AXRole.application, title: "企业微信", children: [
            AXNode(role: AXRole.window, title: "张三", children: [
                AXNode(role: AXRole.row, title: "张三"),
                AXNode(role: AXRole.row, title: "文件传输助手"),
            ]),
        ])
        let url = dir.appendingPathComponent("in.json")
        try tree.write(to: url)
        return url
    }

    @Test func fixtureRoundTripRedactsByDefault() throws {
        let input = try fixtureURL()
        let output = input.deletingLastPathComponent().appendingPathComponent("out.json")
        let cmd = try DumpTreeCommand.parse(["--from-fixture", input.path, "--output", output.path])
        let report = try cmd.runPipeline()
        let node = try AXNode.load(from: output)
        #expect(node.children[0].title != "张三")
        #expect(node.children[0].children[1].title == "文件传输助手")
        #expect(report.nodes == 4)
        #expect(report.roles["AXRow"] == 2)
        #expect(report.redacted)
    }

    @Test func rawKeepsText() throws {
        let input = try fixtureURL()
        let output = input.deletingLastPathComponent().appendingPathComponent("out.raw.json")
        let cmd = try DumpTreeCommand.parse(["--from-fixture", input.path, "--output", output.path, "--raw"])
        let report = try cmd.runPipeline()
        #expect(try AXNode.load(from: output).children[0].title == "张三")
        #expect(!report.redacted)
        #expect(report.render().contains("nodes: 4"))
    }
}
