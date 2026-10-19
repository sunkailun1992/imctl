import SwiftUI

/// The integration docs shipped with the app (Contents/Resources/docs, copied
/// by scripts/build-app.sh from docs/protocol at build time; a development
/// binary reads the repo). Re-read every 5 s while shown and whenever the
/// file changes, so the page always shows the current text (user request
/// 2026-09-15: 对接文档在界面里直接看、实时更新).
struct DocsView: View {
    @State private var chosen = DocsLocator.files[0]
    @State private var directory: URL? = DocsLocator.directory()
    @State private var text = ""
    @State private var blocks: [MarkdownBlock] = []
    @State private var modified: Date?

    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    func load() {
        guard let dir = directory else { text = ""; blocks = []; modified = nil; return }
        let url = dir.appendingPathComponent(chosen)
        modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            text = ""; blocks = [MarkdownBlock(kind: .paragraph, text: "读不到 \(url.lastPathComponent)")]; return
        }
        if content != text { text = content; blocks = MarkdownStyler.blocks(content) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("文件", selection: $chosen) {
                    ForEach(DocsLocator.files, id: \.self) { Text(DocsLocator.titles[$0] ?? $0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 340)
                Button("重新读取") { directory = DocsLocator.directory(); load() }
            }
            Text(directory.map { _ in "修改于 \(modified.map { Self.stamp.string(from: $0) } ?? "-") · 每 5 s 自动检查" }
                 ?? "找不到文档目录：包内 Contents/Resources/docs，或仓库 docs/protocol（可用 IMCTL_DOCS_DIR 指定）")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .onAppear(perform: load)
        .onChange(of: chosen) { load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                load()
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, level <= 2 ? 10 : 4).textSelection(.enabled)
        case .code:
            Text(block.text).font(.body.monospaced()).textSelection(.enabled).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 6))
        case .table:
            ScrollView(.horizontal) { Text(block.text).font(.callout.monospaced()).textSelection(.enabled) }
        case .bullet:
            HStack(alignment: .top, spacing: 6) { Text("•"); inline(block.text) }
        case .paragraph:
            inline(block.text)
        }
    }

    func inline(_ s: String) -> some View {
        let styled = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map(Text.init) ?? Text(s)
        return styled.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
