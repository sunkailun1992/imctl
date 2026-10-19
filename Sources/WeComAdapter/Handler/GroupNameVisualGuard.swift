/// Fixed local rejection stages for group-name observation. No AX text,
/// handles, user input, or other observed values belong in these reasons.
enum GroupNameVisualGuard: String {
    case unclassified
    case context
    case headerTraversal
    case headerCandidate
    case headerField
    case directDialog
    case identity
    case windowSetCount
    case indicatorShape
    case indicatorButton
    case accessoryOverlap

    func suffix(for error: AIPlannerVisionError) -> String {
        error == .staleView ? " [guardReason=\(rawValue)]" : ""
    }
}
