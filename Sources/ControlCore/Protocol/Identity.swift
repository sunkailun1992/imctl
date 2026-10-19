import Foundation
import GRDB

public enum IdentityKind: String, Codable, CaseIterable {
    case group
    case customer
}

/// One row of the identity bridge: a platform id and the title the client
/// shows for it (the group name, or the remark we set on a customer). Filled
/// by the WeCom API commands (B5) or by hand with `imctl identity set`.
public struct Identity: Codable, Equatable, FetchableRecord, TableRecord {
    public static let databaseTableName = "identities"

    public var kind: IdentityKind
    public var id: String
    public var title: String
    public var updatedMs: Int64

    enum CodingKeys: String, CodingKey {
        case kind, id, title
        case updatedMs = "updated_ms"
    }

    public init(kind: IdentityKind, id: String, title: String, updatedMs: Int64) {
        self.kind = kind; self.id = id; self.title = title; self.updatedMs = updatedMs
    }

    public var conversationType: ConversationType { kind == .group ? .group : .customer }
}

/// Read side of the bridge so adapters and watchers do not depend on the store.
public protocol IdentityLookup {
    func identity(kind: IdentityKind, id: String) throws -> Identity?
    func identities(title: String) throws -> [Identity]
}

public struct NoIdentities: IdentityLookup {
    public init() {}
    public func identity(kind: IdentityKind, id: String) throws -> Identity? { nil }
    public func identities(title: String) throws -> [Identity] { [] }
}
