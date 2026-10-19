/// Kind of conversation a target or event refers to. `unknown` is a
/// legitimate value: a conversation whose kind cannot be derived from the
/// client is only ever allowed by an explicit title or id rule, never by a
/// type rule, and `internal` is not inferred at all in v0.2 (no AX evidence).
public enum ConversationType: String, Codable, Equatable, CaseIterable {
    /// Group chat (customer group or colleagues); messages carry a sender label.
    case group
    /// One-to-one chat with an external contact (WeChat user or another company's member).
    case customer
    /// One-to-one chat with a colleague of the same company.
    case `internal`
    case unknown
}
