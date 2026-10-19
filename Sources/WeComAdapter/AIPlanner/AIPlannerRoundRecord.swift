import ControlCore
import Foundation

/// B54: one model request inside an explicit visual command, as fixed categories only. No image, prompt,
/// model text, candidate label, title, name, phone number or greeting is kept.
public struct AIPlannerRoundRecord: Equatable {
    public let method: RPCMethod
    /// `AIPlannerGoal.logName`: the goal's kind, never its title or name.
    public let goal: String
    public let phase: AIPlannerPhase
    /// 1-based within one visual step (one runner or selector).
    public let round: Int
    /// The model's step (`verify`, `reobserve`, `stop`, `selectRow`, …) or a fixed error name.
    public let outcome: String
    public let latencyMs: Int
    /// `contact.add`'s result-row round only: the chosen result's source (wechat | wecom), a fixed category.
    public let contactSource: AIPlannerContactSource?

    public init(method: RPCMethod, goal: String, phase: AIPlannerPhase, round: Int, outcome: String, latencyMs: Int,
                contactSource: AIPlannerContactSource? = nil) {
        self.method = method; self.goal = goal; self.phase = phase
        self.round = round; self.outcome = outcome; self.latencyMs = latencyMs
        self.contactSource = contactSource
    }

    /// The daemon log line.
    public var line: String {
        "vision round \(method.rawValue) \(goal)/\(phase.rawValue) #\(round) → \(outcome) (\(latencyMs) ms)"
            + (contactSource.map { " source=\($0.rawValue)" } ?? "")
    }

    /// This round as the command record's view of how the visual part ended.
    public func ended(_ outcome: String) -> CommandDiagnosis.Visual {
        CommandDiagnosis.Visual(goal: goal, phase: phase.rawValue, round: round, outcome: outcome)
    }
}

extension AIPlannerGoal {
    /// The goal's kind for logs and diagnoses: titles and names are never included.
    public var logName: String {
        switch self {
        case .conversationRow: "conversationRow"
        case .contactRow: "contactRow"
        case .requestCard: "requestCard"
        case .groupMember: "groupMember"
        case .historyScrollBar: "historyScrollBar"
        case .pickerContactsScrollBar: "pickerContactsScrollBar"
        case .control(let purpose): purpose.rawValue
        }
    }
}

extension AIPlannerVisionError {
    /// The case name (`timeout`, `staleView`, …): no case carries a value, so it is fixed and content-free.
    public var logName: String { String(describing: self) }
}

extension AIPlannerReversibleOutcome {
    public var logName: String {
        switch self {
        case .verified: "verify"
        case .stopped: "stop"
        case .unverified: "unverified"
        }
    }
}

/// B54: model requests of one runner or selector, numbered from 1.
final class AIPlannerRoundCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// B54: runs one model request and reports it to `sink` as a fixed-category record; never retries.
func recordedDecision(_ context: AIPlannerStepContext, round: Int, now: () -> TimeInterval,
                      sink: ((AIPlannerRoundRecord) -> Void)?,
                      _ decide: () throws -> AIPlannerStepDecision) throws -> AIPlannerStepDecision {
    let started = now()
    func report(_ outcome: String) {
        let elapsed = now() - started
        let ms = elapsed.isFinite ? max(0, Int((elapsed * 1000).rounded())) : 0
        sink?(AIPlannerRoundRecord(method: context.method, goal: context.goal.logName, phase: context.phase,
                                   round: round, outcome: outcome, latencyMs: ms, contactSource: context.contactSource))
    }
    do {
        let decision = try decide()
        report(decision.step.rawValue)
        return decision
    } catch let error as AIPlannerVisionError {
        report(error.logName)
        throw error
    } catch {
        report("error")
        throw error
    }
}
