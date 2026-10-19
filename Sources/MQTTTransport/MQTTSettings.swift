import Foundation
import SystemConfiguration

/// Broker connection and topic layout for one controller. Stored locally
/// (0600) under the imctl data directory; never committed.
public struct MQTTSettings: Codable, Equatable {
    public var host: String
    public var port: Int
    public var controllerID: String
    public var username: String?
    public var password: String?
    public var useTLS: Bool
    public var topicPrefix: String
    public var keepAliveSeconds: Int

    public init(host: String, port: Int = 1883, controllerID: String, username: String? = nil, password: String? = nil,
                useTLS: Bool = false, topicPrefix: String = "im", keepAliveSeconds: Int = 30) {
        self.host = host; self.port = port; self.controllerID = controllerID
        self.username = username; self.password = password; self.useTLS = useTLS
        self.topicPrefix = topicPrefix; self.keepAliveSeconds = keepAliveSeconds
    }

    public var clientID: String { "imctl-\(controllerID)" }
    public var commandTopic: String { "\(topicPrefix)/\(controllerID)/cmd" }
    public var responseTopic: String { "\(topicPrefix)/\(controllerID)/rsp" }
    public var eventTopic: String { "\(topicPrefix)/\(controllerID)/evt" }
    public var stateTopic: String { "\(topicPrefix)/\(controllerID)/state" }
    /// Everything this controller may publish lives under here (per-machine ACL `im/{id}/#`).
    public var ownTopicPrefix: String { "\(topicPrefix)/\(controllerID)/" }
    /// B52: readiness probe messages (a nonce only). Inside `ownTopicPrefix`; no consumer subscribes to it.
    public var readinessTopic: String { "\(topicPrefix)/\(controllerID)/readiness" }

    public static func load(from url: URL) throws -> MQTTSettings {
        try JSONDecoder().decode(MQTTSettings.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: Controller id (B52 addendum, user 2026-10-12)

extension MQTTSettings {
    /// A controller id is one topic level and part of the client id: 1–64 of `A–Z a–z 0–9 . _ -`.
    public static func isValidControllerID(_ id: String) -> Bool {
        (1...64).contains(id.unicodeScalars.count) && id.unicodeScalars.allSatisfy { controllerIDCharacters.contains($0) }
    }

    /// The default on a first enrolment: this Mac's local host name in lower case. Anything outside
    /// `a–z 0–9 . _ -` becomes `-`, runs of `-` collapse, `-` is trimmed at both ends, at most 64 characters;
    /// nil when nothing is left (then the id has to be typed).
    public static func defaultControllerID(localHostName: String?) -> String? {
        guard let name = localHostName?.lowercased() else { return nil }
        var id = ""
        for scalar in name.unicodeScalars {
            let kept = controllerIDCharacters.contains(scalar) ? Character(scalar) : "-"
            if kept == "-", id.hasSuffix("-") { continue }
            id.append(kept)
        }
        let dashes = CharacterSet(charactersIn: "-")
        let capped = String(id.trimmingCharacters(in: dashes).prefix(64)).trimmingCharacters(in: dashes)
        return capped.isEmpty ? nil : capped
    }

    /// `LocalHostName` from System Configuration: no network lookup, nil when unset.
    public static func currentLocalHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    /// Typed first, then the id already enrolled (re-enrolling must not move this Mac to another topic tree,
    /// or the Java side's commands reach nobody), then the host-name default. Empty strings count as absent.
    public static func resolveControllerID(explicit: String?, existing: String?, hostDefault: String?) -> String? {
        for candidate in [explicit, existing, hostDefault] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    private static let controllerIDCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
}
