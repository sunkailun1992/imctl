import AXKit
import ControlCore
import CoreGraphics
import Foundation

public enum MessageRowKind: String, Codable {
    /// A bubble (text area body, or a non-centered static text fallback).
    case message
    /// A bubble without accessible text — picture, sticker, card: the row's cell has no text children
    /// (live 2026-09-15 21:19, 5.0.11: a 246 px row).
    case media
    /// A file card (live 2026-09-22, 5.0.11): an `AXImage` described `file <type> emphasized`, the file
    /// name and a size label ("74K"), 82 px.
    case file
    /// A native video (live 2026-09-22): an `AXImage` described `… play action play …` and a duration
    /// label ("01:14"), ≥ 300 px.
    case video
    /// Centered notice without a bubble: joins, recalls, group renames.
    case system
    /// A row that only carries a time label.
    case timeSeparator
    case empty
}

/// The content of a text-less `media` row, when the client exposes evidence for it.
/// The row itself can also be a sticker or card, so it must stay unknown without
/// a matching conversation preview (5.0.11, 2026-09-23).
public enum MessageMediaType: String, Codable {
    case image
    case unknown
}

public struct MessageRow: Equatable {
    public var index: Int
    public var kind: MessageRowKind
    public var text: String?
    public var timeLabel: String?
    public var bodyFrame: CGRect?
    public var direction: MessageDirection
    /// Group chats show the sender above the bubble; nil for our own bubbles and private chats.
    public var senderLabel: String?
    public var frame: CGRect
    public var handle: AXElementHandle
    /// Assigned by `WeComReader.chatMessages()`; nil straight from the parser.
    public var messageKey: String? = nil
    /// file rows: the name and size label the client shows, and the icon's type word (pdf, word, excel, ppt, zip, …).
    public var fileName: String? = nil
    public var fileSize: String? = nil
    public var fileType: String? = nil
    /// video rows: the duration label ("01:14").
    public var duration: String? = nil
    /// Only for `kind == .media`; `image` requires the selected conversation's
    /// latest preview to agree with this being its latest visible message.
    public var mediaType: MessageMediaType? = nil
    /// An AXValue read failed twice for a child of this row. A partial row is
    /// kept visible but must not be treated as complete message evidence.
    public var readError: String? = nil
}

public enum MessageMediaTypeInference {
    /// A list preview describes only the latest message. It cannot classify
    /// older media rows, nor can a generic tall, empty AX row prove it is an
    /// image. Do not infer from size, cache timestamps or the conversation name.
    public static func enrichLatest(_ messages: inout [MessageRow], selected: ConversationRow?, activeTitle: String?) {
        guard selected?.selected == true, let last = messages.indices.last, messages[last].kind == .media else { return }
        if let activeTitle, selected?.title != activeTitle { return }
        messages[last].mediaType = selected?.preview?.trimmingCharacters(in: .whitespacesAndNewlines) == "[图片]" ? .image : .unknown
    }
}

/// Turns message-table rows into `MessageRow`s. Body = first `AXTextArea`
/// (falls back to the first non-time `AXStaticText`); time = a static text
/// matching `TimeLabel`; sender = a non-time static text above the body. A
/// static-text-only row whose text is horizontally centered is a system
/// notice, never a message (synthetic group fixture; live shape confirmed
/// against the test group during B4 live checks).
public struct MessageRowParser {
    public var direction = DirectionInference()
    /// |text centre − table centre| ≤ this fraction of the table width ⇒ centered.
    public var centeredTolerance: CGFloat = 0.12
    /// A centered body wider than this fraction of the table is a long message, not a notice.
    public var noticeMaxWidthFraction: CGFloat = 0.5
    /// A text-less row at least this tall is a media bubble rather than padding or a bare time separator.
    public var mediaRowMinHeight: CGFloat = 100

    public init() {}

    static let durationPattern = try? NSRegularExpression(pattern: "^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$")
    static func isDuration(_ s: String) -> Bool { durationPattern.map { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } ?? false }
    static func isPlayIcon(_ description: String) -> Bool { description.contains("play action play") }
    /// "file pdf emphasized" → "pdf".
    static func fileType(from description: String) -> String? {
        let parts = description.split(separator: " ")
        guard parts.count >= 2, parts[0] == "file" else { return nil }
        return String(parts[1])
    }

    /// AXElement retries one transient -25201 read. If that also fails for
    /// this child, retain an explicit partial row rather than losing history.
    /// Permission and other client failures still propagate.
    static func readableValue(_ element: AXElement, readError: inout String?) throws -> String? {
        do {
            return try element.valueString()
        } catch AXKitError.apiFailure(let code, let operation) where code == -25201 && operation == "get AXValue" {
            readError = "AX_VALUE_UNAVAILABLE"
            return nil
        }
    }

    /// `images`: frames of pictures / avatars drawn in the message pane; the largest one
    /// overlapping a media row gives that row its direction.
    public func parse(table: AXElement, tableFrame: CGRect, images: [CGRect] = []) throws -> [MessageRow] {
        var rows: [MessageRow] = []
        for (index, row) in try table.children().enumerated() {
            guard try row.role() == AXRole.row else { continue }
            let frame = try row.frame() ?? .zero
            let cell = try row.children().first { try $0.role() == AXRole.cell } ?? row
            var statics: [(String, CGRect)] = []
            var labels: [(String, CGRect)] = []   // clickable sender names (external groups render them as buttons, live 2026-09-15)
            var icons: [(String, CGRect)] = []    // described AXImage children: file icons, the video play button (live 2026-09-22)
            var rowImages: [CGRect] = []           // avatars / pictures inside this row, excluded from the layout walk
            var body: (String, CGRect)?
            var unreadableTextFrame: CGRect?
            var readError: String?
            for child in try cell.children() {
                switch try child.role() {
                case AXRole.textArea:
                    if body == nil {
                        let f = try child.frame() ?? .zero
                        if let value = try Self.readableValue(child, readError: &readError) {
                            body = (value, f)
                        } else if readError != nil {
                            unreadableTextFrame = f
                        } else {
                            body = ("", f)
                        }
                    }
                case AXRole.staticText:
                    if let v = try Self.readableValue(child, readError: &readError) {
                        statics.append((v, try child.frame() ?? .zero))
                    }
                case AXRole.button:
                    if let t = try child.title(), !t.isEmpty {
                        labels.append((t, try child.frame() ?? .zero))
                    }
                case AXRole.image:
                    let f = try child.frame() ?? .zero
                    if f.width >= 40 { rowImages.append(f) }
                    if let d = try child.axDescription(), !d.isEmpty { icons.append((d, f)) }
                default:
                    continue
                }
            }
            let playIcon = icons.first { Self.isPlayIcon($0.0) }
            let fileIcon = icons.first { Self.fileType(from: $0.0) != nil }
            // A video's duration looks like a time label; the row's own label is the centered one.
            let timeLike = statics.filter { TimeLabel.matches($0.0) }
            let time = timeLike.first { isCentered($0.1, in: tableFrame) } ?? (playIcon == nil ? timeLike.first : nil)
            let nonTime = statics.filter { !TimeLabel.matches($0.0) }
            var kind = MessageRowKind.message
            var anchor: CGRect? = body?.1 ?? unreadableTextFrame
            var fileName: String?, fileSize: String?, fileType: String?, duration: String?
            if let playIcon {
                kind = .video
                anchor = playIcon.1
                duration = timeLike.first { !isCentered($0.1, in: tableFrame) && Self.isDuration($0.0) }?.0
                body = nil
            } else if let fileIcon, let name = nonTime.first(where: { FileSizeLabel.bytes($0.0) == nil && $0.1.maxY > fileIcon.1.minY }) {
                // The name sits beside / under the icon; a static entirely above it is the group sender label,
                // which comes first among the cell's children (review 2026-09-22).
                kind = .file
                anchor = name.1
                fileName = name.0
                fileSize = nonTime.first { FileSizeLabel.bytes($0.0) != nil }?.0
                fileType = Self.fileType(from: fileIcon.0)
                body = nil
            } else if let b = body {
                // A centered, short text area is a notice the client renders as a text area (live 2026-09-15: 以上是打招呼的内容 …).
                if isCentered(b.1, in: tableFrame), b.1.width <= tableFrame.width * noticeMaxWidthFraction { kind = .system }
            } else if unreadableTextFrame != nil {
                // The AXTextArea proves this is a text row even when its value is unreadable.
                kind = .message
            } else if let first = nonTime.first {
                body = first
                anchor = first.1
                if isCentered(first.1, in: tableFrame) { kind = .system }
            } else if readError != nil {
                // Never relabel an unreadable text/time label as an image.
                kind = .message
                anchor = frame
            } else if frame.height >= mediaRowMinHeight {
                // A tall row with no text is a picture / sticker; the first one after a time gap carries
                // its own time label in the same row (live 2026-09-16: a 388 px row whose only child was "11:01").
                kind = .media
            } else {
                kind = time == nil ? .empty : .timeSeparator
            }
            if kind == .media {
                anchor = (images + rowImages).filter { $0.minY < frame.maxY && $0.maxY > frame.minY }
                    .max { $0.width * $0.height < $1.width * $1.height }
            }
            // Sender = a static text above the bubble, or a button above it that starts no further right than the bubble
            // (the clickable "名字@微信" of an external group); the WeChat tag is not part of the name.
            let senderCandidate = [MessageRowKind.message, .file, .video].contains(kind) ? anchor.flatMap { a in
                nonTime.first { $0.1.maxY <= a.minY && $0.1 != a && $0.0 != fileName } ?? labels.first { $0.1.maxY <= a.minY && $0.1.minX <= a.minX + 20 }
            } : nil
            let sender = senderCandidate.map { Self.senderName(from: $0.0) }
            let directed = [MessageRowKind.message, .media, .file, .video].contains(kind)
            let geometricDirection = anchor.map { direction.infer(body: $0, container: tableFrame) } ?? .unknown
            // An inbound group bubble has a separate sender label near the left edge.
            // Use it only when the bubble itself is ambiguous; never override a clear
            // outbound frame or treat a centered annotation as sender-side evidence.
            let senderSide = senderCandidate.map { direction.infer(body: $0.1, container: tableFrame) }
            let resolvedDirection: MessageDirection = geometricDirection == .unknown && senderSide == .inbound ? .inbound : geometricDirection
            rows.append(MessageRow(
                index: index, kind: kind, text: body?.0, timeLabel: time?.0, bodyFrame: anchor,
                direction: directed ? resolvedDirection : .unknown,
                senderLabel: sender, frame: frame, handle: row.handle,
                fileName: fileName, fileSize: fileSize, fileType: fileType, duration: duration,
                mediaType: kind == .media ? .unknown : nil, readError: readError
            ))
        }
        return rows
    }

    /// "华Jie@微信" → "华Jie": the trailing WeChat tag marks the source, not the name (company suffixes stay).
    public static func senderName(from label: String) -> String {
        label.hasSuffix("@微信") ? String(label.dropLast(3)) : label
    }

    func isCentered(_ rect: CGRect, in table: CGRect) -> Bool {
        guard table.width > 0 else { return false }
        return abs(rect.midX - table.midX) <= table.width * centeredTolerance
    }
}
