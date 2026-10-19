import AXKit
import CoreGraphics
import Foundation

public struct ConversationRow: Equatable {
    public var index: Int
    public var title: String?
    public var preview: String?
    public var timeLabel: String?
    /// Value of the small text area some rows carry (unread count / draft mark), verbatim.
    public var badge: String?
    /// Title of the avatar image, if any; may carry a type marker.
    public var avatarTitle: String?
    /// List tags the client shows next to the title ("微信" for WeChat
    /// contacts, "外部" for external groups); never part of title or preview.
    public var markers: [String]
    public var selected: Bool
    public var frame: CGRect
    public var handle: AXElementHandle
}

/// Turns `AXRow > AXCell > [AXImage, AXStaticText…, AXGroup, AXTextArea?]`
/// into `ConversationRow`s using geometry only:
/// - markers = static texts equal to a known list tag (removed before layout)
/// - timeLabel = a time-looking text hugging the cell's right edge
/// - top band = remaining texts whose minY is within `bandTolerance` of the topmost
/// - title = leftmost top-band text
/// - preview = text below the title in the same column
public struct ConversationRowParser {
    public var bandTolerance: CGFloat = 4
    public var rightEdgeTolerance: CGFloat = 40
    public var columnTolerance: CGFloat = 8
    /// 5.0.x list tags; confirmed against live rows during B4 live checks.
    public var markerTexts: Set<String> = ["微信", "外部", "外部群"]
    /// Zero-width and blank characters the client pads a tag with (live 2026-09-15: "外部\u{200B}").
    static let tagNoise = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}"))

    public init() {}

    public func parse(table: AXElement) throws -> [ConversationRow] {
        var rows: [ConversationRow] = []
        for (index, row) in try table.children().enumerated() {
            guard try row.role() == AXRole.row else { continue }
            let frame = try row.frame() ?? .zero
            guard frame.height > 0 else { continue }
            let cell = try row.children().first { try $0.role() == AXRole.cell } ?? row
            let cellFrame = try cell.frame() ?? frame
            var texts: [(String, CGRect)] = []
            var markers: [String] = []
            var badge: String?
            var avatarTitle: String?
            for child in try cell.children() {
                switch try child.role() {
                case AXRole.staticText:
                    if let v = try child.valueString(), let f = try child.frame() {
                        if markerTexts.contains(v) { markers.append(v) } else { texts.append((v, f)) }
                    }
                case AXRole.textArea:
                    // 5.0.11 puts an external group's 外部 tag in this slot instead of a static text.
                    if badge == nil, let v = try child.valueString() {
                        let tag = v.trimmingCharacters(in: Self.tagNoise)
                        if markerTexts.contains(tag) { markers.append(tag) } else { badge = v }
                    }
                case AXRole.image:
                    if avatarTitle == nil { avatarTitle = try child.title() }
                default:
                    continue
                }
            }
            let fields = assign(texts: texts, cellFrame: cellFrame)
            rows.append(ConversationRow(
                index: index, title: fields.title, preview: fields.preview, timeLabel: fields.time,
                badge: badge, avatarTitle: avatarTitle, markers: markers,
                selected: (try row.isSelected() ?? cell.isSelected()) ?? false,
                frame: frame, handle: row.handle
            ))
        }
        return rows
    }

    private func assign(texts: [(String, CGRect)], cellFrame: CGRect) -> (title: String?, preview: String?, time: String?) {
        // Time hugs the cell's right edge (on 5.0.10 it shares the preview line, not the title line).
        let time = texts.first { cellFrame.maxX - $0.1.maxX <= rightEdgeTolerance && TimeLabel.matches($0.0) }
        let rest = texts.filter { $0.1 != time?.1 }
        guard let topY = rest.map({ $0.1.minY }).min() else { return (nil, nil, time?.0) }
        let band = rest.filter { $0.1.minY - topY <= bandTolerance }
        let title = band.min { $0.1.minX < $1.1.minX }
        var preview: String?
        if let title {
            preview = rest
                .filter { $0.1.minY > title.1.maxY - bandTolerance && abs($0.1.minX - title.1.minX) <= columnTolerance }
                .min { $0.1.minY < $1.1.minY }?.0
        }
        return (title?.0, preview, time?.0)
    }
}
