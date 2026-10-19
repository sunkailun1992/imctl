import Foundation

/// How the daemon treats 通讯录 › 新的客户 requests and what it does after
/// accepting one. Lives in policy.json (a human's local decision); default is
/// everything off. Java can only accept individually, in `remote` mode.
public struct ContactRequestPolicy: Codable, Equatable {
    public enum AcceptMode: String, Codable, CaseIterable { case off, all, rules, remote }
    public enum GroupMode: String, Codable, CaseIterable { case off, perPerson }

    public var autoAccept: AcceptMode
    public var allowNames: [String]
    public var greetingContains: [String]
    public var autoGroup: GroupMode
    public var groupDefaultMembers: [String]
    public var groupNameSuffix: String
    /// B9 (user 2026-09-16): the group name is a template with `{客户名}`; default `{客户名}群聊`.
    /// A template without the placeholder falls back to customer name + `groupNameSuffix`.
    public var groupNameTemplate: String
    public var maxAcceptsPerHour: Int

    public static let customerPlaceholder = "{客户名}"
    public static let defaultTemplate = "{客户名}群聊"

    public init(autoAccept: AcceptMode = .off, allowNames: [String] = [], greetingContains: [String] = [], autoGroup: GroupMode = .off,
                groupDefaultMembers: [String] = [], groupNameSuffix: String = "群聊", groupNameTemplate: String = ContactRequestPolicy.defaultTemplate,
                maxAcceptsPerHour: Int = 20) {
        self.autoAccept = autoAccept; self.allowNames = allowNames; self.greetingContains = greetingContains; self.autoGroup = autoGroup
        self.groupDefaultMembers = groupDefaultMembers; self.groupNameSuffix = groupNameSuffix; self.groupNameTemplate = groupNameTemplate
        self.maxAcceptsPerHour = maxAcceptsPerHour
    }

    enum CodingKeys: String, CodingKey { case autoAccept, allowNames, greetingContains, autoGroup, groupDefaultMembers, groupNameSuffix, groupNameTemplate, maxAcceptsPerHour }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoAccept = try c.decodeIfPresent(AcceptMode.self, forKey: .autoAccept) ?? .off
        allowNames = try c.decodeIfPresent([String].self, forKey: .allowNames) ?? []
        greetingContains = try c.decodeIfPresent([String].self, forKey: .greetingContains) ?? []
        autoGroup = try c.decodeIfPresent(GroupMode.self, forKey: .autoGroup) ?? .off
        groupDefaultMembers = try c.decodeIfPresent([String].self, forKey: .groupDefaultMembers) ?? []
        groupNameSuffix = try c.decodeIfPresent(String.self, forKey: .groupNameSuffix) ?? "群聊"
        groupNameTemplate = try c.decodeIfPresent(String.self, forKey: .groupNameTemplate) ?? Self.defaultTemplate
        maxAcceptsPerHour = try c.decodeIfPresent(Int.self, forKey: .maxAcceptsPerHour) ?? 20
    }

    /// Whether the daemon itself accepts this request (`remote` and `off` never do).
    public func decides(name: String, greeting: String?) -> Bool {
        switch autoAccept {
        case .off, .remote: return false
        case .all: return true
        case .rules:
            if allowNames.contains(name) { return true }
            guard let greeting, !greeting.isEmpty else { return false }
            return greetingContains.contains { !$0.isEmpty && greeting.contains($0) }
        }
    }

    /// User decisions 2026-09-15 / 09-16: `{客户名}群聊` by default, configurable as a template.
    public func groupName(for customer: String) -> String {
        guard groupNameTemplate.contains(Self.customerPlaceholder) else { return customer + groupNameSuffix }
        return groupNameTemplate.replacingOccurrences(of: Self.customerPlaceholder, with: customer)
    }

    public var summary: String { "requests=\(autoAccept.rawValue)/\(autoGroup.rawValue)" }
}
