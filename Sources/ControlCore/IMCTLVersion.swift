/// Build identity of the controller. Kept in ControlCore so every target
/// (CLI, daemon, adapters) reports the same version and bundle identifier.
public enum IMCTLVersion {
    /// 1.0.0 (2026-09-16): the feature set the user signed off as the first stable release (B1–B12).
    /// 1.0.1 (2026-09-22): the Full Disk Access probe also reads the system TCC database (macOS 27.0 has no per-user one).
    /// 1.0.2 (2026-09-23): B13 — message.sendFile (outbox → ⌘V → Return), file / video rows, message.media over OSS signed URLs, imctl oss.
    /// 1.0.3 (2026-09-23): B14 — group.addMembers (添加群成员 sheet, dryRun, probe), allowlist completion (allowAll, type toggles, entry edits, chatId / externalUserId lists).
    /// 1.0.4 (2026-09-24): B15 — on-demand in-memory window frame for visible AX-unknown media direction; daemon Screen Recording grant.
    /// 1.0.5 (2026-09-24): B16 — opt-in cloud vision selects a verified AX candidate for an explicit group-header action.
    /// 1.0.6-dev (2026-09-24): B17 — bounded AI observation for fixed desktop command steps; pending live gate.
    /// 1.0.7-dev (2026-09-24): B18 — bounded reversible visual rounds for a conversation.read parser miss.
    /// 1.0.8-dev (2026-09-24): B19 — revoke stale single-step visual decisions after settings, policy or target changes.
    /// 1.0.9-dev (2026-09-25): B20 — bounded visual target-selection rounds for four fixed mutation commands.
    /// 1.0.10-dev (2026-09-25): B21/B22 — bounded ambiguous history scrolling and one transient AX role/frame read retry.
    /// 1.0.11-dev (2026-09-25): B23/B24/B25 — bounded contact/group opening rounds and AX edge evidence for history scrolling.
    /// 1.0.12-dev (2026-09-25): B26–B30 — contact/picker opening guards, staged send/rename proof and member identity verification.
    /// 1.0.13-dev (2026-09-26): B31/B32 — one-pass message probe and outbound evidence for text / attachment sends.
    /// 1.0.14-dev (2026-09-26): B34–B36 — bounded visual conversation/read navigation and direct-send composer observations.
    /// 1.0.15-dev (2026-10-11): B52 — controller.readiness / imctl doctor: per-capability readiness with background live tests.
    /// 1.0.16-dev (2026-10-12): B53 — setup wizard, readiness page and confirmed quick fixes; `imctl doctor --fix`.
    /// 1.0.17-dev (2026-10-13): B54 — the standalone verification window's invite prompt; visual rounds logged; command records carry a diagnosis when a visual round ended them.
    /// 1.0.18-dev (2026-10-19): reconcile a group rename applied by AXValue before visual verification; preserve the checkpoint before the first value write.
    /// 1.0.19-dev (2026-10-19): recognize the bounded window-sharing indicator during passive group-title checks without accepting other dialogs.
    /// 1.0.20-dev (2026-10-19): clarify passive group-title observation anchors and background editors while retaining the model's stop veto.
    /// 1.0.21-dev (2026-10-19): prepare an off-Space group window with one bounded AXFrontmost request before the unchanged visual and window-set guards.
    /// 1.0.22-dev (2026-10-19): report fixed, content-free group-title guard reasons without changing rejection or reconciliation.
    /// 1.0.23-dev (2026-10-19): preserve top-left window image orientation so JPEG pixels align with AX observation boxes.
    /// 1.0.24-dev (2026-10-19): allow owned group-title width changes after fixed staging; never compensate or blur an uncertain rename.
    /// 1.0.25-dev (2026-10-27): B61 — per-call AX timings (state.json, ax-timings.json, rate-limited log) and batched attribute reads for row parsing, layout location and tree dumps; read-only AX timing probe.
    /// 1.0.26-dev (2026-10-28): B62 — B61 review follow-ups: monotonic AX timing windows, batching switched off when the client never answers a batch, named whole-batch timeouts, GCD queues labelled other; CI also runs every suite with batching fakes.
    public static let string = "1.0.26-dev"
    /// Code-signing identifier; must stay stable so TCC (Accessibility)
    /// authorization survives rebuilds.
    public static let bundleIdentifier = "com.sunkailun.imctl"
}
