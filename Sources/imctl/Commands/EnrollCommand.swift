import ArgumentParser
import Foundation
import MQTTTransport

struct EnrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Write the local MQTT settings (broker, controller id, optional credentials). Stored 0600, never committed.",
        discussion: "The controller id defaults to the one already enrolled, else to this Mac's local host name in lower case."
    )

    @Option(help: "Broker host[:port] (default port 1883).") var broker: String
    @Option(name: .customLong("controller-id"), help: "This Mac's controller id (one machine, one account, one id; 1–64 of A–Z a–z 0–9 . _ -).") var controllerID: String?
    @Option var username: String?
    @Option var password: String?
    @Flag var tls = false
    @Option(name: .customLong("topic-prefix")) var topicPrefix: String = "im"
    @Option(help: "Settings file path.") var config: String = MQTTSettings.defaultURL.path

    /// The id to enroll and where it came from: typed, else the one in `settingsURL`, else this Mac's local host name.
    /// A settings file that exists but cannot be read stops here (review I1): guessing would move this Mac to another
    /// topic tree, and the Java side's commands would reach nobody.
    static func resolvedControllerID(explicit: String?, settingsURL: URL, localHostName: String?) throws -> (id: String, source: String) {
        var enrolled: String?
        if explicit?.isEmpty != false, FileManager.default.fileExists(atPath: settingsURL.path) {
            do { enrolled = try MQTTSettings.load(from: settingsURL).controllerID } catch {
                throw ValidationError("\(settingsURL.path) exists but cannot be read (\(error)); pass --controller-id <the id the Java side sends to>, or remove the file")
            }
        }
        let hostDefault = MQTTSettings.defaultControllerID(localHostName: localHostName)
        guard let id = MQTTSettings.resolveControllerID(explicit: explicit, existing: enrolled, hostDefault: hostDefault) else {
            throw ValidationError("this Mac has no local host name to derive a controller id from; pass --controller-id")
        }
        guard MQTTSettings.isValidControllerID(id) else {
            throw ValidationError("controller id \"\(id)\" must be 1–64 of A–Z a–z 0–9 . _ - (it is one topic level)")
        }
        if explicit?.isEmpty == false { return (id, "") }
        if enrolled?.isEmpty == false { return (id, " (kept from the enrolled settings)") }
        return (id, " (this Mac's local host name; it must be unique on this broker)")
    }

    func run() throws {
        let url = URL(fileURLWithPath: config)
        let (controllerID, source) = try Self.resolvedControllerID(explicit: controllerID, settingsURL: url,
                                                                    localHostName: MQTTSettings.currentLocalHostName())
        let parts = broker.split(separator: ":", maxSplits: 1).map(String.init)
        let host = parts[0]
        let port = parts.count > 1 ? Int(parts[1]) ?? 1883 : (tls ? 8883 : 1883)
        let settings = MQTTSettings(host: host, port: port, controllerID: controllerID, username: username, password: password,
                                    useTLS: tls, topicPrefix: topicPrefix)
        try settings.save(to: url)
        print("saved \(config) (0600)")
        print("controller id: \(controllerID)\(source)")
        print("client_id: \(settings.clientID)")
        print("topics: cmd=\(settings.commandTopic) rsp=\(settings.responseTopic) evt=\(settings.eventTopic) state=\(settings.stateTopic)")
    }
}
