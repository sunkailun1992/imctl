import ArgumentParser
import ControlCore
import Foundation
import WeComAdapter

struct PolicyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Maintain policy.json: the local allowlist widening on top of the compiled-in 文件传输助手. Opening a real customer or group is a human decision; record it in the wiki.",
        subcommands: [PolicyListCommand.self, PolicyAllowCommand.self, PolicyDenyCommand.self, PolicyRequestsCommand.self, PolicyRemoteCommand.self, PolicyAllCommand.self, PolicyReadsCommand.self, PolicyPhonesCommand.self, PolicyHostsCommand.self]
    )
}

/// Rule flags shared by allow / deny.
struct PolicyRuleOptions: ParsableArguments {
    @Option(name: .customLong("title"), parsing: .upToNextOption, help: "Conversation title(s) exactly as the client shows them.") var titles: [String] = []
    @Option(name: .customLong("chat-id"), parsing: .upToNextOption, help: "Group chat_id(s); usable once the identity bridge maps them to a title.") var chatIds: [String] = []
    @Option(name: .customLong("external-user-id"), parsing: .upToNextOption, help: "Customer external_userid(s).") var externalUserIds: [String] = []
    @Option(name: .customLong("type"), parsing: .upToNextOption, help: "Conversation type(s): group, customer, internal. unknown can never be allowed.") var types: [String] = []
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func rules() throws -> [SendPolicy.Rule] {
        var out: [SendPolicy.Rule] = titles.map { .title($0) } + chatIds.map { .chatId($0) } + externalUserIds.map { .externalUserId($0) }
        for t in types {
            guard let type = ConversationType(rawValue: t), type != .unknown else {
                throw ValidationError("--type must be group, customer or internal (got \(t))")
            }
            out.append(.type(type))
        }
        guard !out.isEmpty else { throw ValidationError("give at least one --title / --chat-id / --external-user-id / --type") }
        return out
    }
}

struct PolicyAllowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "allow", abstract: "Add rules to policy.json (0600). imctld reloads the file within one poll.")
    @OptionGroup var options: PolicyRuleOptions

    func validate() throws { _ = try options.rules() }

    func apply() throws -> SendPolicy {
        let url = URL(fileURLWithPath: options.file)
        var policy = try SendPolicy.load(from: url)
        for rule in try options.rules() { policy.allow(rule) }
        try policy.save(to: url)
        return policy
    }

    func run() throws {
        let policy = try apply()
        print("wrote \(options.file) (0600): \(policy.summary)")
        print("effective titles: \(PolicyView.effectiveTitles(policy).joined(separator: ", "))")
        print("imctld reloads the file within one poll; check `imctl status` (policy) or the controller.state{policy} event")
    }
}

struct PolicyDenyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deny", abstract: "Remove rules from policy.json.")
    @OptionGroup var options: PolicyRuleOptions

    func validate() throws { _ = try options.rules() }

    func apply() throws -> SendPolicy {
        let url = URL(fileURLWithPath: options.file)
        var policy = try SendPolicy.load(from: url)
        for rule in try options.rules() { policy.deny(rule) }
        try policy.save(to: url)
        return policy
    }

    func run() throws {
        let policy = try apply()
        print("wrote \(options.file) (0600): \(policy.summary)")
        print("effective titles: \(PolicyView.effectiveTitles(policy).joined(separator: ", "))")
    }
}

struct PolicyView: Codable {
    var file: String
    var present: Bool
    var compiled: [String]
    var policy: SendPolicy
    var effectiveTitles: [String]

    static func effectiveTitles(_ policy: SendPolicy) -> [String] {
        Array(Set([WeComClient.fileTransferAssistantTitle] + policy.allowedTitles)).sorted()
    }
}

struct PolicyListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show the compiled allowlist, the policy file rules and the effective titles.")
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path
    @Flag var json = false

    func collect() throws -> PolicyView {
        let url = URL(fileURLWithPath: file)
        let policy = try SendPolicy.load(from: url)
        return PolicyView(file: file, present: FileManager.default.fileExists(atPath: file), compiled: [WeComClient.fileTransferAssistantTitle],
                          policy: policy, effectiveTitles: PolicyView.effectiveTitles(policy))
    }

    func run() throws {
        let view = try collect()
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(view), as: UTF8.self))
        } else {
            print("file: \(view.file) (\(view.present ? "present" : "absent"))")
            print("compiled: \(view.compiled.joined(separator: ", "))")
            print("titles: \(view.policy.allowedTitles.joined(separator: ", "))")
            let types = view.policy.allowedTypes.enabledNames
            print("types: \(types.isEmpty ? "-" : types.joined(separator: ", "))")
            print("chatIds: \(view.policy.allowedChatIds.joined(separator: ", "))")
            print("externalUserIds: \(view.policy.allowedExternalUserIds.joined(separator: ", "))")
            print("effective titles: \(view.effectiveTitles.joined(separator: ", "))")
            print("allowAll: \(view.policy.allowAll)\(view.policy.allowAll ? " — 任何会话都可发送（含类型 unknown）；关闭：imctl policy all --disable" : "")")
            print("reads: \(view.policy.gateReads ? "gated (conversation.read needs an allowed title)" : "open (default: any conversation can be opened / read)") remoteEdits=\(view.policy.remoteEdits)")
            print("phones (contact.add): any number, maxAddsPerHour=\(view.policy.contactAdd.maxAddsPerHour) maxSearchesPerHour=\(view.policy.contactAdd.maxSearchesPerHour)")
            print("hosts (sendFile): \(view.policy.sendFile.allowedHosts.isEmpty ? "-" : view.policy.sendFile.allowedHosts.joined(separator: ", ")) maxBytes=\(view.policy.sendFile.maxBytes)")
            let r = view.policy.contactRequests
            print("requests: autoAccept=\(r.autoAccept.rawValue) autoGroup=\(r.autoGroup.rawValue) names=\(r.allowNames.joined(separator: ",")) keywords=\(r.greetingContains.joined(separator: ",")) defaultMembers=\(r.groupDefaultMembers.joined(separator: ",")) suffix=\(r.groupNameSuffix) maxAcceptsPerHour=\(r.maxAcceptsPerHour)")
        }
    }
}

struct PolicyRequestsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "requests",
        abstract: "Contact-request automation in policy.json (hot-reloaded): auto-accept mode and rules, auto group after accepting, default group members, hourly cap."
    )
    @Option(name: .customLong("auto-accept"), help: "off | all | rules | remote") var autoAccept: String?
    @Option(name: .customLong("auto-group"), help: "off | perPerson") var autoGroup: String?
    @Option(name: .customLong("allow-name"), parsing: .upToNextOption, help: "Nickname(s) accepted in rules mode.") var allowNames: [String] = []
    @Option(name: .customLong("greeting-contains"), parsing: .upToNextOption, help: "Greeting keyword(s) accepted in rules mode.") var greetingContains: [String] = []
    @Option(name: .customLong("default-member"), parsing: .upToNextOption, help: "Member(s) added to every automatic group.") var defaultMembers: [String] = []
    @Option(name: .customLong("group-name-suffix"), help: "Legacy: group name = customer name + suffix (used when the template has no {客户名}).") var groupNameSuffix: String?
    @Option(name: .customLong("group-name-template"), help: "Group name template with {客户名}, default {客户名}群聊.") var groupNameTemplate: String?
    @Option(name: .customLong("max-accepts-per-hour"), help: "Hard cap enforced by the executor.") var maxAcceptsPerHour: Int?
    @Flag(name: .customLong("clear-lists"), help: "Replace the name / keyword / member lists instead of appending.") var clearLists = false
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if let a = autoAccept, ContactRequestPolicy.AcceptMode(rawValue: a) == nil { throw ValidationError("--auto-accept must be off, all, rules or remote") }
        if let g = autoGroup, ContactRequestPolicy.GroupMode(rawValue: g) == nil { throw ValidationError("--auto-group must be off or perPerson") }
    }

    func apply() throws -> SendPolicy {
        try validate()
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        var r = policy.contactRequests
        if let a = autoAccept, let mode = ContactRequestPolicy.AcceptMode(rawValue: a) { r.autoAccept = mode }
        if let g = autoGroup, let mode = ContactRequestPolicy.GroupMode(rawValue: g) { r.autoGroup = mode }
        func merge(_ current: [String], _ new: [String]) -> [String] { clearLists ? new : current + new.filter { !current.contains($0) } }
        if clearLists || !allowNames.isEmpty { r.allowNames = merge(r.allowNames, allowNames) }
        if clearLists || !greetingContains.isEmpty { r.greetingContains = merge(r.greetingContains, greetingContains) }
        if clearLists || !defaultMembers.isEmpty { r.groupDefaultMembers = merge(r.groupDefaultMembers, defaultMembers) }
        if let s = groupNameSuffix { r.groupNameSuffix = s }
        if let t = groupNameTemplate, !t.isEmpty { r.groupNameTemplate = t }
        if let m = maxAcceptsPerHour { r.maxAcceptsPerHour = max(0, m) }
        policy.contactRequests = r
        try policy.save(to: url)
        return policy
    }

    func run() throws {
        let policy = try apply()
        let r = policy.contactRequests
        print("wrote \(file) (0600): \(r.summary) names=\(r.allowNames.count) keywords=\(r.greetingContains.count) defaultMembers=\(r.groupDefaultMembers.count) template=\(r.groupNameTemplate) maxAcceptsPerHour=\(r.maxAcceptsPerHour)")
        print("imctld reloads the file within one poll")
    }
}

/// The local switch for `policy.set` over the wire (B9): off by default so widening the allowlist stays a decision made on this Mac.
struct PolicyRemoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remote", abstract: "Enable or disable policy.set over the socket / MQTT (remoteEdits in policy.json).")
    @Flag(help: "Allow policy.set from Java / MQTT.") var enable = false
    @Flag(help: "Refuse policy.set again (default).") var disable = false
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if enable == disable { throw ValidationError("pass exactly one of --enable / --disable") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        policy.remoteEdits = enable
        try policy.save(to: url)
        print("wrote \(file) (0600): remoteEdits=\(policy.remoteEdits)")
        print("imctld reloads the file within one poll")
    }
}

/// B14: the user's 「全部放开」 switch (2026-09-22) — local-only, never through `policy.set`. On,
/// `ActionPolicy.allows` returns true for any resolved target, including conversation type `unknown`;
/// phase, enabled and gateReads still gate independently. Off by default.
struct PolicyAllCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "all", abstract: "Enable or disable allowAll in policy.json — 全部放开：开启后任何会话都可发送（含类型 unknown）。只本机；policy.set 不接受。")
    @Flag(help: "Allow every resolved target, including type unknown (全部放开).") var enable = false
    @Flag(help: "Restore the normal allowlist (default).") var disable = false
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if enable == disable { throw ValidationError("pass exactly one of --enable / --disable") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        policy.allowAll = enable
        try policy.save(to: url)
        if policy.allowAll {
            print("wrote \(file) (0600): allowAll=true — 任何会话都可发送（含类型 unknown）；关闭：imctl policy all --disable")
        } else {
            print("wrote \(file) (0600): allowAll=false")
        }
        print("imctld reloads the file within one poll")
    }
}

/// B10 (user 2026-09-16): opening / reading any conversation is unrestricted by default; this switch
/// puts `conversation.read` and history scrollback back behind the allowlist.
struct PolicyReadsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reads", abstract: "Whether conversation.read / scrollback must pass the allowlist (gateReads in policy.json; default open).")
    @Flag(help: "Reads must target an allowed title.") var gate = false
    @Flag(help: "Any conversation can be opened and read (default).") var open = false
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if gate == open { throw ValidationError("pass exactly one of --gate / --open") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        policy.gateReads = gate
        try policy.save(to: url)
        print("wrote \(file) (0600): gateReads=\(policy.gateReads)")
        print("imctld reloads the file within one poll")
    }
}

/// B12: `contact.add`'s hourly caps. Since 2026-10-13 (user decision) any number may be searched and added, so
/// there is no list of numbers to edit here any more; real adds and searches each have a cap (0 = off).
struct PolicyPhonesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "phones", abstract: "Set contact.add's hourly caps on real adds and on searches (any number may be added; a sent request cannot be taken back; 0 = off).")
    @Option(name: .customLong("max-per-hour"), help: "Hard cap on successful adds per hour (0 turns real adds off).") var maxPerHour: Int?
    @Option(name: .customLong("max-searches-per-hour"), help: "Hard cap on searches (dryRun) per hour (0 turns searches off).") var maxSearchesPerHour: Int?
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if maxPerHour == nil, maxSearchesPerHour == nil { throw ValidationError("pass --max-per-hour or --max-searches-per-hour") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        if let maxPerHour { policy.contactAdd.maxAddsPerHour = max(0, maxPerHour) }
        if let maxSearchesPerHour { policy.contactAdd.maxSearchesPerHour = max(0, maxSearchesPerHour) }
        try policy.save(to: url)
        print("wrote \(file) (0600): \(policy.contactAdd.summary)")
        print("imctld reloads the file within one poll")
    }
}

/// B13: which https hosts `message.sendFile` may download from (policy.json sendFile.allowedHosts; empty = refused).
struct PolicyHostsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hosts", abstract: "Allow / deny https hosts for message.sendFile (exact host or .suffix; empty list = every url refused) and the per-file byte cap.")
    @Option(parsing: .upToNextOption, help: "Host(s) to allow, e.g. cdn.example or .aliyuncs.com") var allow: [String] = []
    @Option(parsing: .upToNextOption, help: "Host(s) to deny.") var deny: [String] = []
    @Option(name: .customLong("max-bytes"), help: "Hard cap on one downloaded file.") var maxBytes: Int64?
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if allow.isEmpty, deny.isEmpty, maxBytes == nil { throw ValidationError("pass --allow, --deny or --max-bytes") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        for h in allow { policy.sendFile.allow(h) }
        for h in deny { policy.sendFile.deny(h) }
        if let m = maxBytes { policy.sendFile.maxBytes = max(1, m) }
        try policy.save(to: url)
        print("wrote \(file) (0600): \(policy.sendFile.summary) [\(policy.sendFile.allowedHosts.joined(separator: ", "))]")
        print("imctld reloads the file within one poll")
    }
}
