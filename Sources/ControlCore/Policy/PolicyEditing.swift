/// The daemon's policy file as seen over the wire (`policy.get` / `policy.set`).
/// Widening stays a human's local decision: `apply` must refuse unless
/// `SendPolicy.remoteEdits` was switched on here (`imctl policy remote --enable`).
public protocol PolicyEditing: AnyObject {
    func current() throws -> SendPolicy
    /// Allows / denies titles and sendFile hosts, replaces `contactRequests` and sets `gateReads` when given; returns the saved policy.
    func apply(allow: [String], deny: [String], contactRequests: ContactRequestPolicy?, gateReads: Bool?,
               allowHosts: [String], denyHosts: [String]) throws -> SendPolicy
}
