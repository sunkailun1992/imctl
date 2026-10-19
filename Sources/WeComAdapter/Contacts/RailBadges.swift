import AXKit
import CoreGraphics

/// The navigation rail exposes no labelled items. Each item owns a disabled
/// `AXButton` (its count as title, empty without one) directly followed by a
/// 2×2 `AXImage` anchor among the children of the window's split group; the
/// rail's `AXSplitter` is its right edge. Recorded on 5.0.11: 2026-09-15/16 on the
/// 160 pt rail (anchors 32 pt apart) and 2026-09-28 on the 60 pt rail (56 pt
/// apart). The anchors form one evenly spaced column in rail order; a count
/// button is either a sliver on its anchor or drawn at the item's icon (16 pt
/// above the anchor on the wide rail, 31 pt on the narrow one), so neither a
/// window-relative band nor a sliver x-position finds 通讯录 on both rails.
///
/// No AX text names an item, so two recorded 5.0.11 facts identify 通讯录 and
/// both must hold in the live tree: the client lists its pair second, and its
/// anchor is the tenth of the evenly spaced column (on 2026-09-15 the rail
/// listed 通讯录 10th of 12 items, and every logged `openContacts` reached it with
/// ⌘8 and two ⌃Tab). Every 5.0.11 recording, wide or narrow, shows the same list
/// order → rail order mapping; 5.0.10 lists its pairs differently and fails
/// both. The client version itself is not checked: a later version is read
/// only while both facts still hold. A reordered rail, an unreadable element or
/// any other structural doubt leaves the count unknown; the watcher then keeps
/// the last attributed count and feeds nothing to the request trigger, so no
/// automatic round (a visible switch to 通讯录) starts on a guess. Read from any
/// view, so the daemon sees pending requests without leaving 消息.
public enum RailBadges {
    /// 5.0.11 lists the 通讯录 badge pair second among the split group's children.
    static let contactsListIndex = 1
    /// On the user's 5.0.11 rail 通讯录 is the tenth item of the evenly spaced column.
    static let contactsRailIndex = 9
    /// Anchors are 2×2 pt markers; nothing else in the split group is that small.
    static let anchorMaxSide: CGFloat = 4
    /// Anchors of one column share their x and repeat one spacing within this tolerance.
    static let alignmentTolerance: CGFloat = 2

    /// One badge pair as the client lists it.
    public struct Slot: Equatable, Codable {
        /// Order of the pair among the split group's children (0 = first listed).
        public var listIndex: Int
        /// Position in the evenly spaced rail column from the top; nil below or apart from it.
        public var railIndex: Int?
        /// The badge title as a count (0 when empty); nil when it is not a count or could not be read.
        public var count: Int?
        /// Vertical offset of the count button's centre from its anchor, in rail spacings.
        public var badgeOffset: Double?
        /// Whether the count button lies left of the rail's splitter.
        public var badgeInRail: Bool
    }

    public struct Reading: Equatable, Codable {
        public var slots: [Slot] = []
        /// Distance between consecutive anchors of the rail column; nil when no column was found.
        public var spacing: Double?
        /// The 通讯录 count; nil when the rail is not the recognised layout.
        public var contacts: Int?
        /// Why `contacts` is nil; nil when it was read.
        public var problem: String?
    }

    /// The 通讯录 count, 0 when it is zero or cannot be attributed.
    public static func newCustomersBadge(window: AXElement) -> Int { read(window: window).contacts ?? 0 }

    public static func read(window: AXElement) -> Reading {
        var reading = Reading()
        func unknown(_ problem: String) -> Reading {
            reading.contacts = nil
            reading.problem = problem
            return reading
        }
        // A sheet hung off the window comes first among its children; the rail stays in the one split group.
        let splits = ((try? window.children()) ?? []).filter { (try? $0.role()) == AXRole.splitGroup }
        guard splits.count == 1, let children = try? splits[0].children() else { return unknown("no single split group") }
        let splitters = children.filter { (try? $0.role()) == AXRole.splitter }
        guard splitters.count == 1, let railEdge = ((try? splitters[0].frame()) ?? nil)?.minX else {
            return unknown("no single rail splitter")
        }

        // A read that fails here (the client's transient AX errors) is doubt, not an
        // absent element: a skipped pair would renumber the list or the column.
        var pairs: [(button: AXElement, anchor: CGRect)] = []
        for (index, child) in children.enumerated() {
            let role: String?, frame: CGRect?
            do { role = try child.role() } catch { return unknown("rail element unreadable") }
            guard role == AXRole.image else { continue }
            do { frame = try child.frame() } catch { return unknown("rail anchor unreadable") }
            guard let frame, frame.width <= anchorMaxSide, frame.height <= anchorMaxSide else { continue }
            let buttonRole: String?
            do { buttonRole = index > 0 ? try children[index - 1].role() : nil } catch { return unknown("rail element unreadable") }
            guard buttonRole == AXRole.button else { return unknown("anchor without a badge button") }
            pairs.append((children[index - 1], frame))
        }
        guard pairs.count > contactsListIndex else { return unknown("\(pairs.count) badge pairs") }
        guard let columnX = pairs.first?.anchor.midX,
              pairs.allSatisfy({ abs($0.anchor.midX - columnX) <= alignmentTolerance && $0.anchor.midX < railEdge }) else {
            return unknown("anchors not in one column left of the rail splitter")
        }

        // The column runs down from the topmost anchor while one spacing repeats;
        // items below a gap (the rail's footer) stay outside it.
        let byY = pairs.indices.sorted { pairs[$0].anchor.midY < pairs[$1].anchor.midY }
        let spacing = pairs[byY[1]].anchor.midY - pairs[byY[0]].anchor.midY
        guard spacing > anchorMaxSide else { return unknown("overlapping anchors") }
        reading.spacing = Double(spacing)
        var railIndex: [Int: Int] = [byY[0]: 0]
        for k in 1..<byY.count {
            let gap = pairs[byY[k]].anchor.midY - pairs[byY[k - 1]].anchor.midY
            guard abs(gap - spacing) <= alignmentTolerance else { break }
            railIndex[byY[k]] = k
        }

        reading.slots = pairs.enumerated().map { listIndex, pair in
            let badge = (try? pair.button.frame()) ?? nil
            // A title that cannot be read is no count, never an empty (zero) badge.
            let title: String??
            do { title = .some(try pair.button.title()) } catch { title = .none }
            return Slot(listIndex: listIndex, railIndex: railIndex[listIndex],
                        count: title.flatMap { count(title: $0) },
                        badgeOffset: badge.map { Double(($0.midY - pair.anchor.midY) / spacing) },
                        badgeInRail: badge.map { $0.minX < railEdge } ?? false)
        }
        let contacts = reading.slots[contactsListIndex]
        guard contacts.railIndex == contactsRailIndex else {
            return unknown("通讯录 pair at rail slot \(contacts.railIndex.map(String.init) ?? "none"), expected \(contactsRailIndex)")
        }
        guard let value = contacts.count else { return unknown("通讯录 badge title unreadable or not a count") }
        // A count sits on its own anchor (sliver) or at its item's icon, above
        // the anchor (−0.5 spacing wide, −0.55 narrow, recorded) and inside the
        // rail. Lower down, or a full spacing away, it could be a neighbour's.
        if value > 0 {
            guard contacts.badgeInRail, let offset = contacts.badgeOffset, offset > -1, offset <= 0.1 else {
                return unknown("通讯录 count button away from its rail item")
            }
        }
        reading.contacts = value
        return reading
    }

    /// Empty → 0, "12" → 12, "99+" → 99; anything else is not a count.
    static func count(title: String?) -> Int? {
        guard let title, !title.isEmpty else { return 0 }
        let digits = title.hasSuffix("+") ? String(title.dropLast()) : title
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
