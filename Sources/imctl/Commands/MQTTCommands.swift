import ArgumentParser
import Foundation
import MQTTNIO
import MQTTTransport
import NIOCore
import NIOFoundationCompat

struct MQTTCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mqtt",
        abstract: "Talk to a running imctld over the broker, the way Java would (minimal consumer).",
        subcommands: [MQTTCallCommand.self, MQTTTailCommand.self]
    )
}

enum MQTTCLI {
    static func client(_ settings: MQTTSettings, suffix: String) -> MQTTClient {
        MQTTClient(host: settings.host, port: settings.port, identifier: "imctl-cli-\(suffix)-\(ProcessInfo.processInfo.processIdentifier)",
                   eventLoopGroupProvider: .createNew,
                   configuration: .init(version: .v5_0, userName: settings.username, password: settings.password, useSSL: settings.useTLS))
    }
}

struct MQTTCallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "call", abstract: "Publish one JSON-RPC request to …/cmd and wait for the response.")

    @Argument(help: "Protocol method, e.g. conversation.list or message.send") var method: String
    @Option(help: "JSON object with params.") var params: String = "{}"
    @Option(help: "Seconds to wait for the response (visual desktop commands may take several rounds).") var timeout: Double = 90
    @Option(help: "Settings file path.") var config: String = MQTTSettings.defaultURL.path

    func run() throws {
        let settings = try MQTTSettings.load(from: URL(fileURLWithPath: config))
        let client = MQTTCLI.client(settings, suffix: "call")
        defer { try? client.syncShutdownGracefully() }
        let replyTopic = "\(settings.responseTopic)/cli-\(ProcessInfo.processInfo.processIdentifier)"
        let correlation = UUID().uuidString
        let semaphore = DispatchSemaphore(value: 0)
        var response: String?

        client.addPublishListener(named: "reply") { result in
            guard case .success(let info) = result, info.topicName == replyTopic else { return }
            let corr = info.properties.compactMap { p -> Data? in if case .correlationData(let b) = p { return Data(buffer: b) }; return nil }.first
            guard corr == nil || corr == Data(correlation.utf8) else { return }
            response = String(decoding: Data(buffer: info.payload), as: UTF8.self)
            semaphore.signal()
        }
        _ = try client.v5.connect(cleanStart: true).wait()
        _ = try client.v5.subscribe(to: [MQTTSubscribeInfoV5(topicFilter: replyTopic, qos: .atLeastOnce)]).wait()

        guard let paramsObject = try JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any] else {
            throw ValidationError("--params must be a JSON object")
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": correlation, "method": method, "params": paramsObject]
        let body = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
        var properties = MQTTProperties()
        properties.append(.responseTopic(replyTopic))
        properties.append(.correlationData(ByteBuffer(data: Data(correlation.utf8))))
        _ = try client.v5.publish(to: settings.commandTopic, payload: ByteBuffer(data: body), qos: .atLeastOnce, properties: properties).wait()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            _ = try? client.v5.disconnect().wait()
            throw ValidationError("no response within \(Int(timeout)) s (is imctld running with --mqtt?)")
        }
        _ = try? client.v5.disconnect().wait()
        print(response ?? "")
    }
}

struct MQTTTailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tail", abstract: "Print everything under im/{controller_id}/# for a while.")

    @Option(help: "Seconds to listen.") var seconds: Double = 10
    @Option(help: "Settings file path.") var config: String = MQTTSettings.defaultURL.path

    func run() throws {
        let settings = try MQTTSettings.load(from: URL(fileURLWithPath: config))
        let client = MQTTCLI.client(settings, suffix: "tail")
        defer { try? client.syncShutdownGracefully() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        client.addPublishListener(named: "tail") { result in
            guard case .success(let info) = result else { return }
            let flags = info.retain ? " [retained]" : ""
            print("\(iso.string(from: Date())) \(info.topicName)\(flags) \(String(decoding: Data(buffer: info.payload), as: UTF8.self))")
            fflush(stdout)
        }
        _ = try client.v5.connect(cleanStart: true).wait()
        _ = try client.v5.subscribe(to: [MQTTSubscribeInfoV5(topicFilter: "\(settings.topicPrefix)/\(settings.controllerID)/#", qos: .atLeastOnce)]).wait()
        Thread.sleep(forTimeInterval: seconds)
        _ = try? client.v5.disconnect().wait()
    }
}
