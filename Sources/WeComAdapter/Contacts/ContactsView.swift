import AXKit
import CoreGraphics
import CryptoKit
import Foundation

/// The 通讯录 view: a left outline (新的客户 / 智能机器人 / <company> /
/// 添加成员...) and, with 新的客户 selected, a right-hand table of request
/// cards (2026-09-15, 5.0.11). Recognised by its texts, never by position.
public enum WeComContactsView {
    public static let newCustomersTitle = "新的客户"
    public static let signatureTexts: Set<String> = ["智能机器人", "添加成员..."]

    public static func texts(in window: AXElement) -> [(String, AXElement)] {
        texts(in: window.descendants(maxDepth: 10, maxNodes: 3000))
    }

    private static func texts(in elements: [AXElement]) -> [(String, AXElement)] {
        elements.compactMap { e in
            guard let role = try? e.role(), role == AXRole.textArea || role == AXRole.staticText,
                  let v = try? e.valueString(), !v.isEmpty else { return nil }
            return (v, e)
        }
    }

    /// One read of the window summarised without its content: text counts,
    /// which signature labels are present, and a short fingerprint of the left
    /// column so consecutive scans show whether the view changed at all
    /// (navigation diagnosis, live 2026-09-15).
    public struct Scan: Equatable {
        public var texts: Int
        public var left: Int
        public var signature: [String]
        public var showing: Bool
        public var fingerprint: String
        public var ms: Int

        public var summary: String {
            "view=\(fingerprint) texts=\(texts) left=\(left) sig=\(signature.isEmpty ? "-" : signature.joined(separator: "+")) showing=\(showing) scan=\(ms)ms"
        }
    }

    public static func scan(window: AXElement) -> Scan {
        let started = Date()
        let elements = window.descendants(maxDepth: 10, maxNodes: 3000)
        let all = texts(in: elements)
        // A right-pane heading may repeat 新的客户. Only one AXOutline row with
        // that label can establish the contacts pane; its actual subtree gives
        // the diagnostic fingerprint, regardless of rail width or screen origin.
        let matches = (try? matchingNewCustomersRows(window: window, includeTextFields: true, elements: elements)) ?? []
        let outline = matches.count == 1 ? matches[0].outline : nil
        let left = outline.map { texts(in: $0).map(\.0) } ?? []
        var values = Set(left)
        // A client variant exposes this row label as AXTextField. The normal
        // parser deliberately leaves selection to the visual fallback there,
        // but the view itself must still be recognised before navigation stops.
        if matches.count == 1 { values.insert(newCustomersTitle) }
        let signature = ([newCustomersTitle] + signatureTexts.sorted()).filter { values.contains($0) }
        let showing = matches.count == 1 && values.contains(newCustomersTitle)
            && !values.isDisjoint(with: signatureTexts)
        let digest = SHA256.hash(data: Data(left.joined(separator: "\n").utf8))
        let fingerprint = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        return Scan(texts: all.count, left: left.count, signature: signature, showing: showing, fingerprint: fingerprint,
                    ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    public static func isShowing(window: AXElement) -> Bool {
        scan(window: window).showing
    }

    /// Selects the 新的客户 row of the left outline, unless the outline already
    /// selects it (the live view opened that way, 2026-09-23) — nothing is
    /// written twice.
    /// - Throws: `WeComError.region("contacts.newCustomersRow")` when no 新的客户
    ///   text sits in a row; `WeComError.region("contacts.outline")` when one
    ///   does but no such row belongs to an outline with a settable AXSelectedRows.
    public static func selectNewCustomers(window: AXElement) throws {
        let (row, outline) = try newCustomersRow(window: window)
        let selected = (try? outline.elements(AXAttribute.selectedRows)) ?? []
        guard !selected.contains(where: { $0.handle == row.handle }) else { return }
        try outline.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
    }

    /// The exact label must be inside one row directly owned by one outline.
    /// A repeated header or duplicate outline row cannot be selected by order.
    static func newCustomersRow(window: AXElement) throws -> (row: AXElement, outline: AXElement) {
        let matches = try matchingNewCustomersRows(window: window, includeTextFields: false)
        if matches.count == 1, try matches[0].outline.isSettable(AXAttribute.selectedRows) {
            return matches[0]
        }
        if !matches.isEmpty { throw WeComError.region("contacts.outline") }
        let rowFound = try texts(in: window).contains { value, text in
            guard value == newCustomersTitle else { return false }
            return try enclosingRow(of: text) != nil
        }
        throw WeComError.region(rowFound ? "contacts.outline" : "contacts.newCustomersRow")
    }

    /// Raw AX evidence for a visual fallback: the exact label must belong to
    /// one row of the left contacts outline. The right pane's identically
    /// titled header cannot enter this set, and duplicate rows remain ambiguous.
    static func exactNewCustomersOutlineRows(window: AXElement) throws -> [(row: AXElement, outline: AXElement)] {
        try matchingNewCustomersRows(window: window, includeTextFields: true).filter {
            try $0.outline.isSettable(AXAttribute.selectedRows)
        }
    }

    private static func matchingNewCustomersRows(window: AXElement, includeTextFields: Bool,
                                                 elements: [AXElement]? = nil) throws -> [(row: AXElement, outline: AXElement)] {
        guard let windowFrame = try window.frame(), windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        let roles = includeTextFields
            ? [AXRole.staticText, AXRole.textArea, AXRole.textField]
            : [AXRole.staticText, AXRole.textArea]
        var matches: [(row: AXElement, outline: AXElement)] = []
        for outline in elements ?? window.descendants(maxDepth: 10, maxNodes: 3000) where (try? outline.role()) == AXRole.outline {
            guard let outlineFrame = try outline.frame(), outlineFrame.width > 0, outlineFrame.height > 0,
                  outlineFrame.intersects(windowFrame) else { continue }
            for row in try outline.children() where (try? row.role()) == AXRole.row {
                guard let rowFrame = try row.frame(), rowFrame.intersects(outlineFrame),
                      row.descendants(maxDepth: 3, maxNodes: 50).contains(where: { element in
                          guard let role = try? element.role(),
                                roles.contains(role),
                                (try? element.valueString()) == newCustomersTitle,
                                let frame = try? element.frame() else { return false }
                          return rowFrame.insetBy(dx: -2, dy: -2).intersects(frame)
                      }) else { continue }
                matches.append((row, outline))
            }
        }
        return matches
    }

    /// A table left over from a previous selection is not proof that an AX
    /// selection landed. Require the exact row in AXSelectedRows as well.
    static func newCustomersSelectionVerified(window: AXElement) throws -> Bool {
        let matches = try exactNewCustomersOutlineRows(window: window)
        guard matches.count == 1,
              let selected = try? matches[0].outline.elements(AXAttribute.selectedRows),
              selected.contains(where: { $0.handle == matches[0].row.handle }) else { return false }
        return try newCustomersTable(window: window) != nil
    }

    /// The `AXRow` at most four parents above `element` (a label sits in a cell of its row).
    static func enclosingRow(of element: AXElement) throws -> AXElement? {
        var node: AXElement? = element
        for _ in 0..<4 {
            node = try node?.parent()
            if (try? node?.role()) == AXRole.row { return node }
        }
        return nil
    }

    /// The cards table fills a measured scroll pane spanning most of the
    /// remaining width right of the unique 新的客户 outline. A narrow unrelated
    /// table, or duplicate plausible tables, cannot prove the page is ready.
    public static func newCustomersTable(window: AXElement) throws -> AXElement? {
        let matches = try matchingNewCustomersRows(window: window, includeTextFields: true)
        guard matches.count == 1, try matches[0].outline.isSettable(AXAttribute.selectedRows),
              let outlineFrame = try matches[0].outline.frame(),
              let windowFrame = try window.frame() else { return nil }
        let remainingWidth = windowFrame.maxX - outlineFrame.maxX
        guard remainingWidth > 0 else { return nil }
        let tables = window.descendants(maxDepth: 10, maxNodes: 3000).filter { table in
            guard (try? table.role()) == AXRole.table, let tableFrame = (try? table.frame()) ?? nil,
                  let pane = (try? table.parent()) ?? nil, (try? pane.role()) == AXRole.scrollArea,
                  let paneFrame = (try? pane.frame()) ?? nil, paneFrame.width > 0, paneFrame.height > 0 else { return false }
            let visible = paneFrame.intersection(windowFrame)
            return paneFrame.minX >= outlineFrame.midX && paneFrame.maxX > outlineFrame.maxX
                && visible.width >= remainingWidth * 0.8
                && visible.width >= paneFrame.width * 0.8 && visible.height >= paneFrame.height * 0.8
                && tableFrame.intersection(paneFrame).width >= paneFrame.width * 0.8
        }
        return tables.count == 1 ? tables[0] : nil
    }
}
