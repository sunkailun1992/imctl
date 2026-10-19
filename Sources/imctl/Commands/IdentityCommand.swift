import ArgumentParser
import ControlCore
import Foundation

struct IdentityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "Maintain the identity bridge (chat_id / external_userid ↔ title) in imctld's database. B5 fills it from the WeCom API; use this for the test group meanwhile.",
        subcommands: [IdentityListCommand.self, IdentitySetCommand.self, IdentityRemoveCommand.self]
    )
}

/// CLI spelling of `IdentityKind` (kept local so ControlCore needs no ArgumentParser conformance).
enum IdentityKindArgument: String, ExpressibleByArgument, CaseIterable {
    case group, customer
    var kind: IdentityKind { self == .group ? .group : .customer }
}

struct IdentityDBOption: ParsableArguments {
    @Option(help: "SQLite path used by imctld.") var db: String = IMCTLPaths.dataDirectory.appendingPathComponent("imctl.sqlite").path
}

struct IdentitySetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Insert or update one bridge entry.")
    @Option(help: "group or customer.") var kind: IdentityKindArgument
    @Option(help: "chat_id (group) or external_userid (customer).") var id: String
    @Option(help: "Title exactly as the client shows it (group name, or the remark set on the customer).") var title: String
    @OptionGroup var store: IdentityDBOption

    func run() throws {
        try ControlStore(path: store.db).upsertIdentity(kind: kind.kind, id: id, title: title, nowMs: Clock.nowMs())
        print("set \(kind.rawValue) \(id) -> \(title)")
    }
}

struct IdentityRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete one bridge entry.")
    @Option(help: "group or customer.") var kind: IdentityKindArgument
    @Option var id: String
    @OptionGroup var store: IdentityDBOption

    func run() throws {
        let removed = try ControlStore(path: store.db).deleteIdentity(kind: kind.kind, id: id)
        print(removed ? "removed \(kind.rawValue) \(id)" : "no entry for \(kind.rawValue) \(id)")
    }
}

struct IdentityListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bridge entries.")
    @OptionGroup var store: IdentityDBOption
    @Flag var json = false

    func collect() throws -> [Identity] { try ControlStore(path: store.db).allIdentities() }

    func run() throws {
        let items = try collect()
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(items), as: UTF8.self))
        } else {
            for i in items { print("\(i.kind.rawValue) \(i.id) -> \(i.title) (updated \(i.updatedMs))") }
            if items.isEmpty { print("no identities") }
        }
    }
}
