import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

struct DumpTreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-tree",
        abstract: "Snapshot an application's accessibility tree as JSON. Read-only; redacted unless --raw."
    )

    @Option(help: "Bundle identifier of the target application.") var bundle: String = WeComClient.bundleID
    @Option(help: "Target by pid instead of bundle identifier.") var pid: Int32?
    @Option(help: "Where to start: app | main-window | focused-window. Windows on another Space are absent from AXChildren/AXWindows but still reachable via AXMainWindow.")
    var root: RootKind = .app
    @Option(help: "Maximum depth below the application element.") var depth: Int = 12
    @Option(name: .customLong("max-children"), help: "Maximum children expanded per node.") var maxChildren: Int = 400
    @Option(parsing: .upToNextOption, help: "Extra attributes captured into `extra`.")
    var extra: [String] = ["AXSelectedRows", "AXSelectedChildren", "AXNumberOfCharacters"]
    @Option(name: .customLong("from-fixture"), help: "Re-run the pipeline on a saved AXNode JSON instead of a live app.")
    var fromFixture: String?
    @Flag(help: "Do not redact. Output path must end with .raw.json.") var raw = false
    @Option(parsing: .upToNextOption, help: "Texts kept verbatim when redacting.")
    var keep: [String] = [WeComClient.fileTransferAssistantTitle]
    @Option(help: "Write JSON here instead of stdout.") var output: String?
    @Flag(help: "Print only the report, not the tree.") var summary = false

    enum RootKind: String, ExpressibleByArgument {
        case app, mainWindow = "main-window", focusedWindow = "focused-window"
    }

    func validate() throws {
        if raw, let output, !output.hasSuffix(".raw.json") {
            throw ValidationError("--raw output must end with .raw.json (that suffix is git-ignored)")
        }
    }

    func run() throws {
        let report = try runPipeline()
        FileHandle.standardError.write(Data((report.render() + "\n").utf8))
    }

    /// The whole pipeline minus printing the report, so tests can drive it
    /// from a fixture.
    func runPipeline() throws -> TreeReport {
        let root = try rootElement()
        let dumper = AXTreeDumper(maxDepth: depth, maxChildren: maxChildren, extraAttributes: extra)
        var (node, stats) = dumper.dumpWithStats(root)
        if !raw {
            node = node.redacted(.default(keepTexts: Set(keep)))
        }
        let report = TreeReport.make(from: node, stats: stats, redacted: !raw)
        if let output {
            try node.write(to: URL(fileURLWithPath: output))
        } else if !summary {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(node), as: UTF8.self))
        }
        return report
    }

    private func rootElement() throws -> AXElement {
        let app: AXElement
        if let fromFixture {
            app = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: fromFixture))).rootElement
        } else {
            let live = LiveAXBackend()
            guard live.isProcessTrusted(prompt: false) else { throw IMCTLError.notTrusted }
            app = try pid.map { AXApp.byPID($0, backend: live) } ?? AXApp.byBundleID(bundle, backend: live)
        }
        switch root {
        case .app: return app
        case .mainWindow:
            guard let w = try app.element(AXAttribute.mainWindow) else { throw IMCTLError.noWindow("AXMainWindow") }
            return w
        case .focusedWindow:
            guard let w = try app.element(AXAttribute.focusedWindow) else { throw IMCTLError.noWindow("AXFocusedWindow") }
            return w
        }
    }
}
