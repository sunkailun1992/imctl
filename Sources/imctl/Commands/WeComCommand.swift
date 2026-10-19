import ArgumentParser
import ControlCore
import Foundation
import WeComAPI

struct WeComCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wecom",
        abstract: "WeCom official-API route through the token-injecting proxy: enroll this controller, check status, call an interface, sync the identity bridge.",
        subcommands: [WeComEnrollCommand.self, WeComStatusCommand.self, WeComCallCommand.self, WeComSyncGroupsCommand.self]
    )
}

struct WeComEnrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enroll", abstract: "Write the proxy address and this controller's Bearer token (0600, never committed).")

    @Option(help: "Proxy base URL, e.g. https://proxy.example.com") var proxy: String
    @Option(help: "Bearer token issued by the proxy for this controller (prefer --token-stdin to keep it out of shell history).") var token: String?
    @Flag(name: .customLong("token-stdin"), help: "Read the token from stdin (first line).") var tokenStdin = false
    @Option(name: .customLong("corp-id"), help: "corpid (only for display / describe; the secret stays on the proxy).") var corpId: String?
    @Option(name: .customLong("agent-id"), help: "agentid of the self-built app.") var agentId: Int?
    @Option(help: "Request timeout in seconds.") var timeout: Double = 15
    @Option(help: "Settings file path.") var config: String = WeComProxySettings.defaultURL.path

    func validate() throws {
        guard proxy.hasPrefix("https://") || proxy.hasPrefix("http://") else { throw ValidationError("--proxy must start with https:// or http://") }
        guard token != nil || tokenStdin else { throw ValidationError("give --token or --token-stdin") }
    }

    func run() throws {
        var value = token ?? ""
        if tokenStdin { value = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty else { throw ValidationError("empty token") }
        let settings = WeComProxySettings(baseURL: proxy, token: value, corpId: corpId, agentId: agentId, timeoutSeconds: timeout)
        try settings.save(to: URL(fileURLWithPath: config))
        print("saved \(config) (0600): \(settings.summary)")
        print("imctld serves group.*/contact.*/broadcast.* through the proxy after its next start")
    }
}

struct WeComStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the proxy settings exist (never prints the token).")

    @Option(help: "Settings file path.") var config: String = WeComProxySettings.defaultURL.path
    @Flag var json = false

    func collect() throws -> [String: Any] {
        var out: [String: Any] = ["file": config, "present": FileManager.default.fileExists(atPath: config)]
        if out["present"] as? Bool == true {
            let s = try WeComProxySettings.load(from: URL(fileURLWithPath: config))
            out["summary"] = s.summary
            out["timeoutSeconds"] = s.timeoutSeconds
        }
        return out
    }

    func run() throws {
        let out = try collect()
        if json {
            print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else {
            for (k, v) in out.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }
        }
    }
}

struct WeComCallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "call", abstract: "POST one WeCom interface through the proxy and print the raw answer (integration probe).")

    @Argument(help: "Interface path, e.g. externalcontact/groupchat/list") var path: String
    @Option(help: "JSON request body.") var body: String = "{}"
    @Option(help: "Settings file path.") var config: String = WeComProxySettings.defaultURL.path

    func run() throws {
        let settings = try WeComProxySettings.load(from: URL(fileURLWithPath: config))
        let response = try URLSessionWeComTransport(settings: settings).post(path: path, body: Data(body.utf8))
        print("HTTP \(response.status)")
        if let object = try? JSONSerialization.jsonObject(with: response.body),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: pretty, as: UTF8.self))
        } else {
            print(String(decoding: response.body, as: UTF8.self))
        }
    }
}

struct WeComSyncGroupsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-groups", abstract: "groupchat/list + get through the proxy; write chat_id ↔ group name into imctld's identity bridge.")

    @Option(help: "Settings file path.") var config: String = WeComProxySettings.defaultURL.path
    @Option(help: "SQLite path used by imctld.") var db: String = IMCTLPaths.dataDirectory.appendingPathComponent("imctl.sqlite").path
    @Option(help: "Page size for groupchat/list.") var limit: Int = 100

    func run() throws {
        let settings = try WeComProxySettings.load(from: URL(fileURLWithPath: config))
        let store = try ControlStore(path: db)
        let handler = WeComAPIHandler(client: WeComAPIClient(transport: URLSessionWeComTransport(settings: settings)), identities: store)
        let synced = try handler.syncGroups(pageLimit: limit)
        for g in synced { print("group \(g.chatId) -> \(g.name)") }
        print("synced \(synced.count) group(s) into \(db)")
    }
}
