import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

/// Options shared by every probe: where the window comes from and how text
/// is printed. Redaction is on by default so probe output can be pasted into
/// gate notes without leaking contact names.
struct ProbeOptions: ParsableArguments {
    @Option(name: .customLong("from-fixture"), help: "Read a saved AXNode JSON (window- or app-rooted) instead of the live client.")
    var fromFixture: String?
    @Option(help: "Bundle identifier of the live client.") var bundle: String = WeComClient.bundleID
    @Flag(help: "Print JSON instead of text.") var json = false
    @Flag(name: .customLong("no-redact"), help: "Print real titles and text (never paste such output into the repo).")
    var noRedact = false
}

enum ProbeSession {
    static func reader(_ options: ProbeOptions) throws -> WeComReader {
        let root: AXElement
        if let path = options.fromFixture {
            root = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: path))).rootElement
        } else {
            let live = LiveAXBackend()
            guard live.isProcessTrusted(prompt: false) else { throw IMCTLError.notTrusted }
            root = try AXApp.byBundleID(options.bundle, backend: live)
        }
        return try WeComReader(window: try WeComWindowLocator.mainWindow(from: root))
    }

    /// The root element: the application when live or for an app-rooted fixture, the window for window-rooted fixtures.
    static func root(_ options: ProbeOptions) throws -> AXElement {
        if let path = options.fromFixture {
            return FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: path))).rootElement
        }
        let live = LiveAXBackend()
        guard live.isProcessTrusted(prompt: false) else { throw IMCTLError.notTrusted }
        return try AXApp.byBundleID(options.bundle, backend: live)
    }

    static func redactor(_ options: ProbeOptions) -> (String?) -> String? {
        if options.noRedact { return { $0 } }
        let policy = AXRedactionPolicy.default(keepTexts: [WeComClient.fileTransferAssistantTitle])
        return { $0.map(policy.redact) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
