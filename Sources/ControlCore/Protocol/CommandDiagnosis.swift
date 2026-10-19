import Foundation

/// B54: why a command ended without success, as fixed categories only — never a title, name, phone number,
/// greeting, prompt or model text. Recorded only when a visual round ended the command.
public struct CommandDiagnosis: Codable, Equatable, Sendable {
    /// The visual step this command ended in, its last model round there, and how it ended. `round` is 0 when
    /// the step ended before its first model request; `goal` / `phase` are `none` when the command ended before
    /// any visual step.
    public struct Visual: Codable, Equatable, Sendable {
        /// A fixed goal kind such as `contactSendVerification` or `conversationRow`.
        public var goal: String
        /// prepare | locate | verify | commit …, or `none`.
        public var phase: String
        /// 1-based within its visual step; 0 before the step's first model round.
        public var round: Int
        /// `stop`, `unverified`, or a fixed vision error name such as `timeout` or `staleView`.
        public var outcome: String

        public init(goal: String, phase: String, round: Int, outcome: String) {
            self.goal = goal; self.phase = phase; self.round = round; self.outcome = outcome
        }
    }

    public var visual: Visual?
    /// Checkpoints this command wrote, each right before an irreversible press; the press itself may or may
    /// not have happened. `contact.add`: 1 = the one before the chosen result's 添加, 2 = the one before 发送
    /// too. No visual step follows 发送, so a diagnosis always means 发送 was not pressed.
    public var irreversibleSteps: Int

    public init(visual: Visual?, irreversibleSteps: Int) {
        self.visual = visual; self.irreversibleSteps = irreversibleSteps
    }

    /// Flat string fields for the `command.state` event payload.
    public var eventFields: [String: String] {
        var fields = ["irreversibleSteps": String(irreversibleSteps)]
        if let visual {
            fields["visualGoal"] = visual.goal
            fields["visualPhase"] = visual.phase
            fields["visualRound"] = String(visual.round)
            fields["visualOutcome"] = visual.outcome
        }
        return fields
    }
}
