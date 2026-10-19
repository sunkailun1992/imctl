import Foundation

/// Where the integration docs are: the copies scripts/build-app.sh puts into
/// Contents/Resources/docs (the same files as docs/protocol at that build), or,
/// for a development binary under <repo>/.build, the repo's docs/protocol.
enum DocsLocator {
    static let files = ["im-control-protocol.md", "java-consumer.md", "wecom-token-proxy.md", "agents-mcp.md"]
    static let titles = ["im-control-protocol.md": "IM Control Protocol", "java-consumer.md": "Java 消费方", "wecom-token-proxy.md": "企微令牌代理", "agents-mcp.md": "Claude Code / Codex 接入"]

    static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                          resources: URL? = Bundle.main.resourceURL, executable: URL? = Bundle.main.executableURL) -> URL? {
        if let dir = environment["IMCTL_DOCS_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) }), has(dir) { return dir }
        if let bundled = resources?.appendingPathComponent("docs", isDirectory: true), has(bundled) { return bundled }
        var dir = executable?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("docs/protocol", isDirectory: true)
            if has(candidate) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    static func has(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(files[0]).path) }
}

struct MarkdownBlock: Equatable {
    enum Kind: Equatable { case heading(Int), paragraph, code, table, bullet }
    var kind: Kind
    var text: String
}

/// Splits Markdown into the few block shapes the docs use (headings, fenced
/// code, pipe tables, bullets, paragraphs); inline styling is left to
/// `AttributedString(markdown:)` at render time.
enum MarkdownStyler {
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []
        func flushParagraph() { if !paragraph.isEmpty { out.append(MarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: " "))); paragraph = [] } }
        func flushTable() { if !table.isEmpty { out.append(MarkdownBlock(kind: .table, text: table.joined(separator: "\n"))); table = [] } }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") { out.append(MarkdownBlock(kind: .code, text: open.joined(separator: "\n"))); code = nil }
                else { open.append(raw); code = open }
                continue
            }
            if line.hasPrefix("```") { flushParagraph(); flushTable(); code = []; continue }
            if line.hasPrefix("|") {
                flushParagraph()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty }) { table.append(cells.joined(separator: "  │  ")) }
                continue
            }
            flushTable()
            if line.isEmpty { flushParagraph(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, line.dropFirst(hashes).hasPrefix(" ") {
                flushParagraph(); out.append(MarkdownBlock(kind: .heading(hashes), text: String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph(); out.append(MarkdownBlock(kind: .bullet, text: String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph(); out.append(MarkdownBlock(kind: .bullet, text: line)); continue
            }
            paragraph.append(line)
        }
        if let open = code { out.append(MarkdownBlock(kind: .code, text: open.joined(separator: "\n"))) }
        flushParagraph(); flushTable()
        return out
    }
}
