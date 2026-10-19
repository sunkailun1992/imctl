import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("Message keys across relative time labels")
struct MessageKeyStabilityTests {
    @Test func preParsedRowsKeepSelfChatDirectionAndPartialKeyBoundary() throws {
        let fake = GroupFixture.backend(messages: [])
        let reader = try WeComReader(window: fake.rootElement)
        let frame = CGRect(x: 400, y: 60, width: 200, height: 30)
        func row(_ index: Int, kind: MessageRowKind, text: String?, readError: String? = nil) -> MessageRow {
            MessageRow(index: index, kind: kind, text: text, timeLabel: "10:21", bodyFrame: frame,
                       direction: .inbound, senderLabel: nil, frame: frame, handle: fake.rootHandle,
                       readError: readError)
        }
        let parsed = [row(0, kind: .timeSeparator, text: nil),
                      row(1, kind: .message, text: "same"), row(2, kind: .message, text: "same"),
                      row(3, kind: .message, text: nil, readError: "AX_VALUE_UNAVAILABLE"),
                      row(4, kind: .message, text: "after"), row(5, kind: .system, text: "notice")]
        let chat = reader.chatMessages(from: parsed, conversationTitle: WeComClient.fileTransferAssistantTitle)
        #expect(chat.map(\.index) == [1, 2, 3, 4])
        #expect(chat.allSatisfy { $0.direction == .outbound })
        #expect(chat[0].messageKey != nil && chat[1].messageKey != nil)
        #expect(chat[0].messageKey != chat[1].messageKey)
        #expect(chat[2].messageKey == nil && chat[3].messageKey == nil)
    }

    @Test func aMediaRowsKeySurvivesMidnightRelabeling() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3_600))
        let dayD = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 17)))
        let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 10)))
        let row = AXNode(role: AXRole.row, frame: CGRect(x: 311, y: 64, width: 1609, height: 240), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 64, width: 1609, height: 240), children: [
                GroupFixture.text("16:36", x: 1102, y: 71, w: 80),
            ]),
        ])
        let fake = GroupFixture.backend(messages: [row])
        let label = try #require(fake.handle(atPath: GroupFixture.messageTablePath + [0, 0, 0]))

        let first = try #require(WeComReader(window: fake.rootElement).chatMessages(now: dayD, calendar: calendar).first)
        #expect(first.kind == .media && first.timeLabel == "16:36" && first.messageKey != nil)

        // The old short label may remain briefly after midnight, before the
        // client's UI changes it to the relative "yesterday" form.
        let staleLabel = try #require(WeComReader(window: fake.rootElement).chatMessages(now: nextDay, calendar: calendar).first)
        #expect(staleLabel.messageKey == first.messageKey)

        fake.mutate(label, attribute: AXAttribute.value, to: .string("昨天 16:36"))
        let second = try #require(WeComReader(window: fake.rootElement).chatMessages(now: nextDay, calendar: calendar).first)
        #expect(second.kind == .media && second.timeLabel == "昨天 16:36")
        #expect(second.messageKey == first.messageKey)
        #expect(MessageTimeLabel.canonicalKeyTime(first.timeLabel, now: dayD, calendar: calendar) == "utc-minute:29835876")
        #expect(MessageTimeLabel.canonicalKeyTime(second.timeLabel, now: nextDay, calendar: calendar) == "utc-minute:29835876")
    }

    @Test func canonicalDaySeparatesOtherwiseIdenticalRowsAndLegacyCandidateIsNarrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3_600))
        let firstDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 17)))
        let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 17)))
        let first = MessageTimeLabel.canonicalKeyTime("16:36", now: firstDay, calendar: calendar)
        let second = MessageTimeLabel.canonicalKeyTime("16:36", now: nextDay, calendar: calendar)
        #expect(first != second)
        #expect(MessageTimeLabel.canonicalKeyTime("unknown", now: nextDay, calendar: calendar) == "unknown")
        #expect(MessageTimeLabel.legacyBareClock("昨天 16:36") == "16:36")
        #expect(MessageTimeLabel.legacyBareClock("昨天 3:05") == "3:05")
        #expect(MessageTimeLabel.legacyBareClock("前天 16:36") == nil)
        #expect(MessageTimeLabel.legacyBareClock("昨天 25:36") == nil)
    }
}
