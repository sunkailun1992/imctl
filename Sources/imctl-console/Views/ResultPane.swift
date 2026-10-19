import AppKit
import SwiftUI

/// The JSON a page got back, the same everywhere (1.0): monospaced, scrollable, selectable, one copy button.
struct ResultPane: View {
    let title: String
    let text: String
    var minHeight: CGFloat = 120

    var body: some View {
        GroupBox {
            ScrollView {
                Text(text.isEmpty ? "（还没有结果）" : text)
                    .font(.callout.monospaced())
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(minHeight: minHeight)
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                CopyButton(text: text)
            }
        }
    }
}

/// One-click copy for short text. The pasteboard stays in this file (ForbiddenAPITests' allowlist).
struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        } label: { Label("复制", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless).disabled(text.isEmpty)
    }
}
