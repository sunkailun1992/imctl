import Testing
@testable import ControlCore

@Suite("MessageKey")
struct MessageKeyTests {
    @Test func keyIsStableAndIndexFree() {
        let a = MessageKey.make(conversation: "g", sender: "张三", timeLabel: "9:18", text: "hi", ordinal: 0)
        #expect(a.count == 16 && a == MessageKey.make(conversation: "g", sender: "张三", timeLabel: "9:18", text: "hi", ordinal: 0))
        #expect(a != MessageKey.make(conversation: "g", sender: nil, timeLabel: "9:18", text: "hi", ordinal: 0))
        #expect(a != MessageKey.make(conversation: "h", sender: "张三", timeLabel: "9:18", text: "hi", ordinal: 0))
    }

    @Test func assignGivesDuplicatesDistinctOrdinalsInDisplayOrder() {
        struct M { var s: String?; var t: String?; var x: String }
        let rows = [M(s: "a", t: nil, x: "ok"), M(s: "b", t: nil, x: "ok"), M(s: "a", t: nil, x: "ok")]
        let keys = MessageKey.assign(rows, conversation: "g", sender: \.s, timeLabel: \.t, text: \.x)
        #expect(Set(keys).count == 3)
        #expect(keys[0] == MessageKey.make(conversation: "g", sender: "a", timeLabel: nil, text: "ok", ordinal: 0))
        #expect(keys[2] == MessageKey.make(conversation: "g", sender: "a", timeLabel: nil, text: "ok", ordinal: 1))
        // prepending unrelated history does not change the keys of the existing rows
        let more = [M(s: "z", t: "8:00", x: "old")] + rows
        #expect(Array(MessageKey.assign(more, conversation: "g", sender: \.s, timeLabel: \.t, text: \.x).dropFirst()) == keys)
    }
}
