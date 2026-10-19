import ControlCore
import Foundation
import MCPTransport

/// Every command the console issues goes through the daemon's socket, so
/// policy, idempotency, the rate cap and the event log apply exactly as they
/// do for Java. Parameter builders are static so tests can check them.
struct RPCService {
    var socketPath: String
    var timeout: TimeInterval = 30

    func call(_ method: String, _ params: [String: JSONValue] = [:]) throws -> JSONValue {
        try UnixSocketClient(path: socketPath, timeout: timeout).call(method, params: params)
    }

    static func idempotencyKey() -> String { "console-\(UUID().uuidString.lowercased())" }

    static func sendParams(target: String, text: String) -> [String: JSONValue] {
        ["target": .string(target), "text": .string(text), "idempotencyKey": .string(idempotencyKey())]
    }

    /// B13: `message.sendFile` — exactly one of `url` / `ossKey` (url wins if both are given), `fileName` optional.
    static func sendFileParams(target: String, url: String, ossKey: String, fileName: String) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["target": .string(target), "idempotencyKey": .string(idempotencyKey())]
        let u = url.trimmingCharacters(in: .whitespaces), k = ossKey.trimmingCharacters(in: .whitespaces), n = fileName.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { p["url"] = .string(u) } else if !k.isEmpty { p["ossKey"] = .string(k) }
        if !n.isEmpty { p["fileName"] = .string(n) }
        return p
    }

    static func broadcastParams(targets: [String], text: String, intervalMs: Int) -> [String: JSONValue] {
        ["targets": .array(targets.map(JSONValue.string)), "text": .string(text), "idempotencyKey": .string(idempotencyKey()), "intervalMs": .number(Double(intervalMs))]
    }

    static func navigateParams(_ action: NavigateAction) -> [String: JSONValue] {
        ["action": .string(action.rawValue), "idempotencyKey": .string(idempotencyKey())]
    }

    static func groupRenameParams(target: String, name: String) -> [String: JSONValue] {
        ["target": .string(target), "name": .string(name), "idempotencyKey": .string(idempotencyKey())]
    }

    static func acceptParams(name: String) -> [String: JSONValue] {
        ["name": .string(name), "idempotencyKey": .string(idempotencyKey())]
    }

    static func contactAddParams(phone: String, source: String, greeting: String, dryRun: Bool) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["phone": .string(phone), "source": .string(source), "dryRun": .bool(dryRun), "idempotencyKey": .string(idempotencyKey())]
        if !greeting.isEmpty { p["greeting"] = .string(greeting) }
        return p
    }

    static func groupCreateParams(members: [String], name: String?) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["members": .array(members.map(JSONValue.string)), "idempotencyKey": .string(idempotencyKey())]
        if let name, !name.isEmpty { p["name"] = .string(name) }
        return p
    }

    /// B14: `group.addMembers` from the 建群 page's 「添加到现有群」 free-text field — split on `,` /
    /// `，` / `、`, trimmed, empties dropped. The first two are the separators `PolicyView.split`
    /// accepts for the console's other manual name lists; `、` is extra here, because this field is
    /// typed as a sentence of names rather than pasted from a list.
    static func groupAddMembersParams(target: String, members: String, dryRun: Bool) -> [String: JSONValue] {
        let list = members.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ["target": .string(target), "members": .array(list.map(JSONValue.string)), "dryRun": .bool(dryRun), "idempotencyKey": .string(idempotencyKey())]
    }

    static func replayParams(after: Int64, limit: Int) -> [String: JSONValue] {
        ["afterEventId": .number(Double(after)), "limit": .number(Double(limit))]
    }

    static func pretty(_ value: JSONValue) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value.any,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }
}
