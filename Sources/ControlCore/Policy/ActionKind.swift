/// Every primitive that changes client state. The policy decides, per kind
/// and per target, whether it may run at all.
public enum ActionKind: String, Codable, CaseIterable {
    case selectConversation
    case composeText
    case clearComposer
    /// Opens the composer's context menu (read the items, then close it).
    case showComposerMenu
    /// Scrolls the message area up so the client loads older history
    /// (`AXScrollBar.AXValue` / `AXScrollUpByPage`; no synthetic input).
    case scrollHistory
    /// The irreversible point. Forbidden in phase 0 regardless of flags.
    case submit
    /// `AXPress` on the send button of the client's 群发助手 task (broadcast.confirm); no target, no typing.
    case confirmBroadcast
    /// `AXPress` on one of the client's own 窗口 menu items (next / previous / next unread conversation); no target.
    case navigate
    /// Switch the client to 通讯录 with its own tab shortcuts and select 新的客户 (B7).
    case openContacts
    /// `AXPress` 接受 on a request card (B7).
    case acceptRequest
    /// `AXPress` the + button to open the 发起群聊 picker sheet (B7).
    case openGroupPicker
    /// Select members in the picker and press 完成 (B7).
    case createGroup
    /// Write the header title field of a group and `AXConfirm` it (B8).
    case renameGroup
    /// 通讯录 › 新的客户 › 添加: type a phone number, one Return, press the match's 添加 (B12; number gated by policy).
    case addContact
    /// B13: put an outbox file URL on the pasteboard, ⌘V into the composer (user-approved 2026-09-22 17:43), then the same Return as `submit`.
    case sendFile
    /// Add members to an already-created group through the same picker sheet as `createGroup`; a
    /// member already in the group is skipped, not reselected. The irreversible point is the sheet's
    /// own 确定, so this is forbidden in phase 0 like `submit` / `sendFile` (2026-09-23).
    case addGroupMembers

    /// Kinds that only change what this Mac's client shows (which conversation is open, how far
    /// its history is scrolled) and nothing the other side can see. Since B10 they pass the target
    /// allowlist unless `SendPolicy.gateReads` is on (user 2026-09-16: reading is unrestricted by default).
    public var isReadOnly: Bool { self == .selectConversation || self == .scrollHistory }

    /// Kinds that act on a named conversation and therefore need an allowlisted target.
    public var requiresTarget: Bool {
        switch self {
        case .selectConversation, .composeText, .submit, .showComposerMenu, .scrollHistory, .renameGroup, .sendFile, .addGroupMembers: return true
        case .clearComposer, .confirmBroadcast, .navigate, .openContacts, .acceptRequest, .openGroupPicker, .createGroup, .addContact: return false
        }
    }
}
