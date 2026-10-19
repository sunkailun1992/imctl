import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("OriginClassifier")
struct OriginClassifierTests {
    @Test func classifierAttributesOnceAndFlagsTakeover() {
        var c = OriginClassifier()
        let sends = [ControllerSend(commandId: "c1", target: "文件传输助手", text: "hi", tsMs: 1)]
        #expect(c.classify(direction: .inbound, text: "hi", conversation: "文件传输助手", sends: sends).origin == .peer)
        let first = c.classify(direction: .outbound, text: "hi", conversation: "文件传输助手", sends: sends)
        #expect(first.origin == .controller && first.commandId == "c1")
        #expect(c.classify(direction: .outbound, text: "hi", conversation: "文件传输助手", sends: sends).origin == .other)
        #expect(c.classify(direction: .outbound, text: "bye", conversation: nil, sends: sends).origin == .other)
        #expect(c.classify(direction: .unknown, text: "zzz", conversation: nil, sends: sends).origin == .unknown)
    }

    @Test func oldestUnconsumedSendWinsAndConversationMustMatch() {
        var c = OriginClassifier()
        let sends = [
            ControllerSend(commandId: "later", target: "文件传输助手", text: "ok", tsMs: 20),
            ControllerSend(commandId: "earlier", target: "文件传输助手", text: "ok", tsMs: 10),
            ControllerSend(commandId: "elsewhere", target: "other-chat", text: "ok", tsMs: 5),
        ]
        #expect(c.classify(direction: .outbound, text: "ok", conversation: "文件传输助手", sends: sends).commandId == "earlier")
        #expect(c.classify(direction: .outbound, text: "ok", conversation: "文件传输助手", sends: sends).commandId == "later")
        #expect(c.classify(direction: .outbound, text: "ok", conversation: "文件传输助手", sends: sends).origin == .other)
        // unknown direction but our own text: attributed to the controller, not left unknown
        var d = OriginClassifier()
        #expect(d.classify(direction: .unknown, text: "ok", conversation: "", sends: sends).origin == .controller)
    }

    /// B13: a pasted picture / file / video has no text to compare; a file row is matched by the name we
    /// pasted, a picture row by the send's file kind (review 2026-09-22).
    @Test func fileSendsAttributeMediaAndFileRowsWithoutText() {
        var c = OriginClassifier()
        let sends = [ControllerSend(commandId: "f1", target: "文件传输助手", text: "", tsMs: 1, kind: "file", fileName: "a.pdf"),
                     ControllerSend(commandId: "f2", target: "文件传输助手", text: "", tsMs: 2, kind: "file", fileName: "b.png"),
                     ControllerSend(commandId: "t1", target: "文件传输助手", text: "hi", tsMs: 3)]
        #expect(c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "file", fileName: "b.pdf").origin == .other)
        let file = c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "file", fileName: "a.pdf")
        #expect(file.origin == .controller && file.commandId == "f1")
        let picture = c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "media")
        #expect(picture.origin == .controller && picture.commandId == "f2")
        #expect(c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "video").origin == .other)
        #expect(c.classify(direction: .outbound, text: "hi", conversation: "文件传输助手", sends: sends).commandId == "t1")
    }

    /// Review 2026-09-22: a peer's picture (direction unreadable, no name to compare) must stay `unknown`
    /// instead of consuming one of our sends, and a picture row is never a document send.
    @Test func mediaRowsNeedAnOutboundDirectionAndACompatibleFileKind() {
        let chat = "文件传输助手"
        var c = OriginClassifier()
        let pdf = [ControllerSend(commandId: "f1", target: chat, text: "", tsMs: 1, kind: "file", fileName: "a.pdf")]
        #expect(c.classify(direction: .unknown, text: nil, conversation: chat, sends: pdf, kind: "media").origin == .unknown)
        #expect(c.classify(direction: .outbound, text: nil, conversation: chat, sends: pdf, kind: "media").origin == .other)
        #expect(c.classify(direction: .outbound, text: nil, conversation: chat, sends: pdf, kind: "file", fileName: "other.pdf").origin == .other)
        // none of those consumed the send, so the row that really carries its name still finds it
        #expect(c.classify(direction: .unknown, text: nil, conversation: chat, sends: pdf, kind: "file", fileName: "a.pdf").commandId == "f1")
        var d = OriginClassifier()
        let media = [ControllerSend(commandId: "p1", target: chat, text: "", tsMs: 1, kind: "file", fileName: "shot.png"),
                     ControllerSend(commandId: "v1", target: chat, text: "", tsMs: 2, kind: "file", fileName: "clip.mp4")]
        #expect(d.classify(direction: .outbound, text: nil, conversation: chat, sends: media, kind: "media").commandId == "p1")
        #expect(d.classify(direction: .outbound, text: nil, conversation: chat, sends: media, kind: "video").commandId == "v1")
        #expect(d.classify(direction: .unknown, text: nil, conversation: chat, sends: media, kind: "video").origin == .unknown)
    }
}
