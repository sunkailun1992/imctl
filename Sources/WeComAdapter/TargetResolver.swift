import ControlCore

/// Turns a wire target into what the policy judges: the title the client must
/// show, the conversation kind, and the platform ids the bridge knows. Client
/// evidence (header, sender labels, list markers) wins over the bridge's kind;
/// the bridge only fills the kind in when the client shows nothing. Reads only.
public struct TargetResolver {
    public var identities: IdentityLookup

    public init(identities: IdentityLookup) { self.identities = identities }

    /// The title to look for. Ids need a bridge entry; otherwise TARGET_NOT_FOUND on the wire form.
    public func title(for ref: TargetRef) throws -> String {
        switch ref {
        case .title(let t): return t
        case .chatId(let id):
            guard let hit = try identities.identity(kind: .group, id: id) else { throw ControlError.targetNotFound(ref.wire) }
            return hit.title
        case .externalUserId(let id):
            guard let hit = try identities.identity(kind: .customer, id: id) else { throw ControlError.targetNotFound(ref.wire) }
            return hit.title
        }
    }

    public func resolve(_ ref: TargetRef, row: ConversationRow?, header: ConversationHeader? = nil, messages: [MessageRow] = []) throws -> ResolvedTarget {
        let title = try title(for: ref)
        var target = ResolvedTarget(title: title)
        for identity in try identities.identities(title: title) {
            switch identity.kind {
            case .group: target.chatId = target.chatId ?? identity.id
            case .customer: target.externalUserId = target.externalUserId ?? identity.id
            }
        }
        if case .chatId(let id) = ref { target.chatId = id }
        if case .externalUserId(let id) = ref { target.externalUserId = id }
        target.type = ConversationTypeInference.infer(header: header, messages: messages, row: row)
        if target.type == .unknown {
            if target.chatId != nil { target.type = .group } else if target.externalUserId != nil { target.type = .customer }
        }
        return target
    }
}
