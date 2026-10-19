import Foundation

/// Conversation kinds a type rule may unlock. `unknown` is never allowed by type.
public struct AllowedTypes: Codable, Equatable {
    public var group: Bool
    public var customer: Bool
    public var `internal`: Bool

    public init(group: Bool = false, customer: Bool = false, internal: Bool = false) {
        self.group = group; self.customer = customer; self.internal = `internal`
    }

    public func allows(_ type: ConversationType) -> Bool {
        switch type {
        case .group: return group
        case .customer: return customer
        case .internal: return `internal`
        case .unknown: return false
        }
    }

    public var enabledNames: [String] {
        [group ? "group" : nil, customer ? "customer" : nil, `internal` ? "internal" : nil].compactMap { $0 }
    }
}

/// The local policy file (`policy.json`, 0600, never committed). It widens the
/// compiled-in allowlist and can never narrow it; edited only through
/// `imctl policy`, and only after a human decided to open a target.
public struct SendPolicy: Codable, Equatable {
    public var allowedTitles: [String]
    public var allowedTypes: AllowedTypes
    public var allowedChatIds: [String]
    public var allowedExternalUserIds: [String]
    /// 通讯录 › 新的客户 automation (B7); absent in older files = everything off.
    public var contactRequests: ContactRequestPolicy
    /// B9: whether `policy.set` over the wire may edit this file. Off by default; a human turns it on
    /// here (`imctl policy remote --enable`), so the decision to widen stays local even when edits come over MQTT.
    public var remoteEdits: Bool
    /// B10: whether read-only actions (`conversation.read`, history scrollback) must also pass the allowlist.
    /// Off by default (user 2026-09-16: no restriction on opening conversations); the allowlist then only gates
    /// what the other side can see — sending, renaming a group, the composer menu.
    public var gateReads: Bool
    /// B12: `contact.add`'s hourly caps (any number since the user's 2026-10-13 decision; 0 turns it off).
    public var contactAdd: ContactAddPolicy
    /// B13: https hosts message.sendFile may fetch from and the per-file byte cap.
    public var sendFile: SendFilePolicy
    /// B14 (user 2026-09-22, 「全部放开」): when true, `ActionPolicy.allows` returns true for any
    /// resolved target, including conversation type `unknown` — `allowAll` is the only exception to
    /// the TYPE rule（类型规则永远不放行 `unknown`；`allowAll` 是用户明确开启、只本机、有日志的唯一
    /// 例外）. Local-only: `imctl policy all --enable|--disable` or the console switch; `policy.set`
    /// never accepts it.
    public var allowAll: Bool

    public init(allowedTitles: [String] = [], allowedTypes: AllowedTypes = AllowedTypes(),
                allowedChatIds: [String] = [], allowedExternalUserIds: [String] = [],
                contactRequests: ContactRequestPolicy = ContactRequestPolicy(), remoteEdits: Bool = false, gateReads: Bool = false,
                contactAdd: ContactAddPolicy = ContactAddPolicy(), sendFile: SendFilePolicy = SendFilePolicy(), allowAll: Bool = false) {
        self.allowedTitles = allowedTitles; self.allowedTypes = allowedTypes
        self.allowedChatIds = allowedChatIds; self.allowedExternalUserIds = allowedExternalUserIds
        self.contactRequests = contactRequests; self.remoteEdits = remoteEdits; self.gateReads = gateReads; self.contactAdd = contactAdd
        self.sendFile = sendFile; self.allowAll = allowAll
    }

    enum CodingKeys: String, CodingKey { case allowedTitles, allowedTypes, allowedChatIds, allowedExternalUserIds, contactRequests, remoteEdits, gateReads, contactAdd, sendFile, allowAll }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedTitles = try c.decodeIfPresent([String].self, forKey: .allowedTitles) ?? []
        allowedTypes = try c.decodeIfPresent(AllowedTypes.self, forKey: .allowedTypes) ?? AllowedTypes()
        allowedChatIds = try c.decodeIfPresent([String].self, forKey: .allowedChatIds) ?? []
        allowedExternalUserIds = try c.decodeIfPresent([String].self, forKey: .allowedExternalUserIds) ?? []
        contactRequests = try c.decodeIfPresent(ContactRequestPolicy.self, forKey: .contactRequests) ?? ContactRequestPolicy()
        remoteEdits = try c.decodeIfPresent(Bool.self, forKey: .remoteEdits) ?? false
        gateReads = try c.decodeIfPresent(Bool.self, forKey: .gateReads) ?? false
        contactAdd = try c.decodeIfPresent(ContactAddPolicy.self, forKey: .contactAdd) ?? ContactAddPolicy()
        sendFile = try c.decodeIfPresent(SendFilePolicy.self, forKey: .sendFile) ?? SendFilePolicy()
        allowAll = try c.decodeIfPresent(Bool.self, forKey: .allowAll) ?? false
    }

    public static let fileName = "policy.json"
    public static var defaultURL: URL { IMCTLPaths.dataDirectory.appendingPathComponent(fileName) }

    /// A missing file is the empty policy (compiled allowlist only). A file that
    /// exists but does not parse throws: the caller must not treat it as "allow".
    public static func load(from url: URL) throws -> SendPolicy {
        guard FileManager.default.fileExists(atPath: url.path) else { return SendPolicy() }
        return try JSONDecoder().decode(SendPolicy.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public enum Rule: Equatable {
        case title(String)
        case chatId(String)
        case externalUserId(String)
        case type(ConversationType)
    }

    public mutating func allow(_ rule: Rule) {
        switch rule {
        case .title(let t): if !allowedTitles.contains(t) { allowedTitles.append(t) }
        case .chatId(let id): if !allowedChatIds.contains(id) { allowedChatIds.append(id) }
        case .externalUserId(let id): if !allowedExternalUserIds.contains(id) { allowedExternalUserIds.append(id) }
        case .type(.group): allowedTypes.group = true
        case .type(.customer): allowedTypes.customer = true
        case .type(.internal): allowedTypes.internal = true
        case .type(.unknown): break
        }
    }

    public mutating func deny(_ rule: Rule) {
        switch rule {
        case .title(let t): allowedTitles.removeAll { $0 == t }
        case .chatId(let id): allowedChatIds.removeAll { $0 == id }
        case .externalUserId(let id): allowedExternalUserIds.removeAll { $0 == id }
        case .type(.group): allowedTypes.group = false
        case .type(.customer): allowedTypes.customer = false
        case .type(.internal): allowedTypes.internal = false
        case .type(.unknown): break
        }
    }

    public var isEmpty: Bool {
        allowedTitles.isEmpty && allowedChatIds.isEmpty && allowedExternalUserIds.isEmpty && allowedTypes.enabledNames.isEmpty
    }

    /// One line for `controller.describe`, `controller.state{policy}` and the CLI. Gains a trailing
    /// `allowAll=true` when the B14 「全部放开」 switch is on (off by default, so old summaries are unchanged).
    public var summary: String {
        let types = allowedTypes.enabledNames.isEmpty ? "-" : allowedTypes.enabledNames.joined(separator: "+")
        let base = "titles=\(allowedTitles.count) types=\(types) chatIds=\(allowedChatIds.count) externalUserIds=\(allowedExternalUserIds.count) \(contactRequests.summary)"
        return allowAll ? "\(base) allowAll=true" : base
    }
}

/// A target after the identity bridge and the client have been consulted:
/// what the policy actually judges.
public struct ResolvedTarget: Equatable {
    public var title: String
    public var type: ConversationType
    public var chatId: String?
    public var externalUserId: String?

    public init(title: String, type: ConversationType = .unknown, chatId: String? = nil, externalUserId: String? = nil) {
        self.title = title; self.type = type; self.chatId = chatId; self.externalUserId = externalUserId
    }
}
