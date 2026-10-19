import ArgumentParser
import Foundation
import WeComAdapter

struct ProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Read-only probes of the WeCom window (phase 0 gates).",
        subcommands: [ProbeConversationsCommand.self, ProbeMessagesCommand.self, ProbeWatchCommand.self, ProbeSelectCommand.self, ProbeComposeCommand.self, ProbeSubmitCommand.self, ProbeMenuCommand.self, ProbeScrollbackCommand.self, ProbeMenuBarCommand.self, ProbeContactsCommand.self, ProbePickerCommand.self, ProbeRowMenuCommand.self, ProbeAddCustomerCommand.self, ProbeAddMembersCommand.self, ProbeRailCommand.self]
    )
}

struct ConversationsOutput: Codable {
    struct Row: Codable {
        var index: Int
        var title: String?
        var preview: String?
        var timeLabel: String?
        var badge: String?
        var avatarTitle: String?
        var selected: Bool
        var y: Double
        var height: Double
        var type: String
        var markers: [String]
    }

    var conversations: [Row]

    func render() -> String {
        conversations.map { r in
            let sel = r.selected ? "*" : " "
            let tags = r.markers.isEmpty ? "" : " markers=\(r.markers.joined(separator: ","))"
            return "#\(r.index) \(sel) \(r.title ?? "-") | \(r.preview ?? "-") | \(r.timeLabel ?? "-") | badge=\(r.badge ?? "-") | type=\(r.type)\(tags) | y=\(Int(r.y)) h=\(Int(r.height))"
        }.joined(separator: "\n")
    }

    func jsonString() throws -> String { try ProbeSession.encode(self) }
}

struct ProbeConversationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "conversations", abstract: "List conversation rows.")

    @OptionGroup var options: ProbeOptions

    func collect() throws -> ConversationsOutput {
        let reader = try ProbeSession.reader(options)
        let redact = ProbeSession.redactor(options)
        let rows = try reader.conversations().map { r in
            ConversationsOutput.Row(
                index: r.index, title: redact(r.title), preview: redact(r.preview), timeLabel: r.timeLabel,
                badge: redact(r.badge), avatarTitle: redact(r.avatarTitle), selected: r.selected,
                y: r.frame.minY, height: r.frame.height,
                type: ConversationTypeInference.infer(row: r).rawValue, markers: r.markers
            )
        }
        return ConversationsOutput(conversations: rows)
    }

    func run() throws {
        let out = try collect()
        print(options.json ? try out.jsonString() : out.render())
    }
}

struct MessagesOutput: Codable {
    struct Row: Codable {
        var index: Int
        var kind: String
        var direction: String
        var timeLabel: String?
        var text: String?
        var sender: String?
        var messageKey: String?
        var minX: Double?
        var maxX: Double?
        var width: Double?
        var y: Double
    }

    var active: String?
    var messages: [Row]
    var composerLength: Int
    var tableMinX: Double
    var tableMaxX: Double

    func render() -> String {
        var lines = ["active: \(active ?? "-")", "table_x: \(Int(tableMinX))-\(Int(tableMaxX))"]
        lines += messages.map { r in
            let x = r.minX.map { "\(Int($0))-\(Int(r.maxX ?? 0))" } ?? "-"
            return "#\(r.index) \(r.kind) dir=\(r.direction) time=\(r.timeLabel ?? "-") x=\(x) y=\(Int(r.y)) sender=\(r.sender ?? "-") key=\(r.messageKey ?? "-") text=\(r.text ?? "-")"
        }
        lines.append("composer: \(composerLength) chars")
        return lines.joined(separator: "\n")
    }

    func jsonString() throws -> String { try ProbeSession.encode(self) }
}

struct ProbeMessagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "messages", abstract: "List visible message rows of the active conversation.")

    @OptionGroup var options: ProbeOptions

    func collect() throws -> MessagesOutput {
        let reader = try ProbeSession.reader(options)
        let redact = ProbeSession.redactor(options)
        return try collect(reader: reader, redact: redact)
    }

    func collect(reader: WeComReader, redact: (String?) -> String?) throws -> MessagesOutput {
        let active = try reader.activeConversationTitle()
        let parsedRows = try reader.messages()
        let keys = Dictionary(uniqueKeysWithValues: reader.chatMessages(from: parsedRows, conversationTitle: active ?? "")
            .compactMap { m in m.messageKey.map { (m.index, $0) } })
        let rows = parsedRows.map { m in
            MessagesOutput.Row(
                index: m.index, kind: m.kind.rawValue, direction: m.direction.rawValue, timeLabel: m.timeLabel, text: redact(m.text),
                sender: redact(m.senderLabel), messageKey: keys[m.index], minX: m.bodyFrame.map { Double($0.minX) },
                maxX: m.bodyFrame.map { Double($0.maxX) }, width: m.bodyFrame.map { Double($0.width) },
                y: m.frame.minY
            )
        }
        return MessagesOutput(
            active: redact(active), messages: rows,
            composerLength: try reader.composerValue()?.count ?? 0,
            tableMinX: Double(reader.layout.messageTableFrame?.minX ?? 0), tableMaxX: Double(reader.layout.messageTableFrame?.maxX ?? 0)
        )
    }

    func run() throws {
        let out = try collect()
        print(options.json ? try out.jsonString() : out.render())
    }
}
