import Foundation

/// Message keys distinguish repeated content only within the currently loaded
/// table. If older identical rows are prepended, an old row can acquire a new
/// key. Confirmation therefore also requires an unchanged visible prefix and
/// rejects a candidate indistinguishable from a row in that prefix.
enum SendEvidence {
    static func newRows(baseline: [MessageRow], observed: [MessageRow]) -> [MessageRow] {
        guard observed.count > baseline.count else { return [] }
        guard zip(baseline, observed).allSatisfy({ same($0.0, $0.1) }) else { return [] }
        return observed.dropFirst(baseline.count).filter { candidate in
            !baseline.contains { same($0, candidate) }
        }
    }

    private static func same(_ a: MessageRow, _ b: MessageRow) -> Bool {
        a.kind == b.kind && a.direction == b.direction && a.text == b.text
            && a.senderLabel == b.senderLabel && a.timeLabel == b.timeLabel
            && a.fileName == b.fileName && a.fileSize == b.fileSize
            && a.fileType == b.fileType && a.duration == b.duration
    }
}
