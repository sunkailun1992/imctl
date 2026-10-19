import AXKit
import ControlCore
import Foundation

/// One fresh, method-scoped observation for a reversible desktop step. The
/// caller supplies eligible AX elements; the model cannot add an operation or
/// choose an element outside this list. A new round may describe a changed UI.
public struct AIPlannerReversibleRound {
    public let window: AXElement
    public let goal: AIPlannerGoal
    public let action: AIPlannerStep
    public let eligible: [AXElement]
    public let expectedTitle: String?
    public let phase: AIPlannerPhase
    public let evidence: AIPlannerEvidence
    /// B54: the chosen result's source, for `contact.add`'s result-row round only.
    public let contactSource: AIPlannerContactSource?

    public init(window: AXElement, goal: AIPlannerGoal, action: AIPlannerStep,
                eligible: [AXElement], expectedTitle: String?,
                phase: AIPlannerPhase, evidence: AIPlannerEvidence,
                contactSource: AIPlannerContactSource? = nil) {
        self.window = window
        self.goal = goal
        self.action = action
        self.eligible = eligible
        self.expectedTitle = expectedTitle
        self.phase = phase
        self.evidence = evidence
        self.contactSource = contactSource
    }
}

public enum AIPlannerReversibleOutcome: Equatable {
    /// The caller's AX postcondition was true. Model output alone cannot produce this result.
    case verified
    /// The model declined to choose an action.
    case stopped
    /// The allowed number of reversible actions was used without AX proof.
    case unverified
}

/// Re-observes after each reversible action under one command-wide budget.
/// The general entry accepts only row selection and scrolling. A separate,
/// method-and-goal-scoped entry accepts one group-header press to open the
/// add-members sheet; it cannot be used to press a member or confirmation.
/// The caller must check
/// the command's policy, target and pause state in `gate`, perform the approved
/// AX operation in `apply`, and prove the resulting state in `verify`.
public struct AIPlannerReversibleRunner {
    public typealias Observe = () throws -> AIPlannerReversibleRound
    public typealias Decide = (AIPlannerObservation, AIPlannerStepContext, CloudVisionSettings) throws -> AIPlannerStepDecision
    public typealias Apply = (AIPlannerStep, AXElement) throws -> Void

    public let maxRounds: Int
    public let maxActions: Int
    public let maxDuration: TimeInterval
    private let beforeRound: () throws -> Void
    private let settingsProvider: () throws -> CloudVisionSettings
    private let capture: AIPlannerObservation.Capture
    private let decide: Decide
    private let now: () -> TimeInterval
    /// B54: one fixed-category record per model request; the handler logs it and keeps the last.
    public var roundSink: ((AIPlannerRoundRecord) -> Void)?
    private let rounds = AIPlannerRoundCounter()

    public init(maxRounds: Int = 6, maxActions: Int = 2, maxDuration: TimeInterval = 40,
                beforeRound: @escaping () throws -> Void,
                settingsProvider: @escaping () throws -> CloudVisionSettings = { try CloudVisionSettings.loadOrDefault() },
                capture: @escaping AIPlannerObservation.Capture = { pid, frame in
                    WeComScreenCapture.capture(windowPID: pid, expectedFrame: frame)
                },
                decide: @escaping Decide = { observation, context, settings in
                    try AIPlannerStepClient().decide(observation: observation, context: context, settings: settings)
                },
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxRounds = maxRounds
        self.maxActions = maxActions
        self.maxDuration = maxDuration
        self.beforeRound = beforeRound
        self.settingsProvider = settingsProvider
        self.capture = capture
        self.decide = decide
        self.now = now
    }

    /// When requested, an AX postcondition starts a fresh, read-only visual
    /// verification round. The model may ask for another observation or stop,
    /// but only a new AX postcondition check can complete the command.
    /// `observe` must still locate the same verified window after the AX
    /// postcondition becomes true.
    public func run(method: RPCMethod, requireVisualPostcondition: Bool = false,
                    gate: () throws -> Void,
                    observe: Observe, apply: Apply,
                    verify: () throws -> Bool) throws -> AIPlannerReversibleOutcome {
        try runRounds(method: method, permitted: { round, _ in [.selectRow, .scroll].contains(round.action) },
                      requireVisualPostcondition: requireVisualPostcondition,
                      gate: gate, observe: observe, apply: apply, verify: verify)
    }

    /// Only `group.addMembers` may use this reversible press, and only for the
    /// fixed Add Group Members control in the group's title band. A second,
    /// read-only visual round must then agree with the caller's fresh AX proof
    /// of that same sheet's title and empty selection before the flow continues.
    public func runAddMembersHeader(gate: () throws -> Void,
                                    observe: Observe, apply: Apply,
                                    verify: () throws -> Bool) throws -> AIPlannerReversibleOutcome {
        guard maxRounds <= 4, maxActions <= 2, maxDuration <= 24 else {
            throw AIPlannerVisionError.invalidGoal
        }
        return try runRounds(method: .groupAddMembers, permitted: { round, awaitingPostcondition in
            guard round.action == .press,
                  awaitingPostcondition
                    ? (round.phase == .verify && round.evidence == .postconditionPresent)
                    : round.phase == .locate else {
                return false
            }
            if case .control(.addGroupMembers) = round.goal { return true }
            return false
        }, requireVisualPostcondition: true,
           gate: gate, observe: observe, apply: apply, verify: verify)
    }

    /// `contact.add` may press only the Add Customer control in the New
    /// Customers header. Searching a number and pressing a match or invitation
    /// are deliberately outside this entry and remain command-owned.
    public func runAddCustomerHeader(gate: () throws -> Void,
                                     observe: Observe, apply: Apply,
                                     verify: () throws -> Bool) throws -> AIPlannerReversibleOutcome {
        guard maxRounds <= 4, maxActions <= 2, maxDuration <= 24 else {
            throw AIPlannerVisionError.invalidGoal
        }
        return try runRounds(method: .contactAdd, permitted: { round, _ in
            guard round.action == .press, round.phase == .locate else { return false }
            if case .control(.addContact) = round.goal { return true }
            return false
        }, requireVisualPostcondition: false,
           gate: gate, observe: observe, apply: apply, verify: verify)
    }

    /// One read-only observation of the uniquely AX-proven chat composer.
    /// The caller owns all staging and supplies the exact AX pre/postcondition;
    /// this entry cannot write text, paste a file, or submit a message. A
    /// second invocation after staging must pass the first one's settings so
    /// a provider, model, key, or local grant change fails closed.
    public func observeComposer(method: RPCMethod, phase: AIPlannerPhase,
                                expectedSettings: CloudVisionSettings? = nil,
                                gate: () throws -> Void, observe: Observe,
                                verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard [.messageSend, .messageSendFile].contains(method) else {
            throw AIPlannerVisionError.invalidGoal
        }
        return try observeStagingField(method: method, phase: phase,
                                       expectedSettings: expectedSettings,
                                       purpose: .messageComposer, role: AXRole.textArea,
                                       gate: gate, observe: observe, verify: verify)
    }

    /// Passive observation of the already AX-proven group title editor. The
    /// caller alone stages the fixed requested name and later confirms it;
    /// this entry cannot select another field or perform either operation.
    public func observeGroupNameField(phase: AIPlannerPhase,
                                      expectedSettings: CloudVisionSettings? = nil,
                                      gate: () throws -> Void, observe: Observe,
                                      verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        try observeStagingField(method: .groupRename, phase: phase,
                                expectedSettings: expectedSettings,
                                purpose: .groupNameField, role: AXRole.textField,
                                gate: gate, observe: observe, verify: verify)
    }

    /// Read-only checks inside the search window opened by this `contact.add`
    /// command. The caller supplies exactly one AX-proven input, source match,
    /// or invitation button; no model decision can perform an AX write.
    public func observeContactAdd(stage: ContactAddVisualStage,
                                  expectedSettings: CloudVisionSettings? = nil,
                                  gate: () throws -> Void, observe: Observe,
                                  verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard (1...6).contains(maxRounds), maxDuration.isFinite,
              maxDuration > 0, maxDuration <= 40 else {
            throw AIPlannerVisionError.invalidGoal
        }
        let descriptor: (AIPlannerControlPurpose, AIPlannerPhase, AIPlannerEvidence, AIPlannerStep, String)
        switch stage {
        case .searchInput:
            descriptor = (.contactSearch, .prepare, .inputReady, .writeText, AXRole.textField)
        case .sourceMatch:
            descriptor = (.contactMatch, .verify, .postconditionPresent, .press, AXRole.button)
        case .inviteConfirm:
            descriptor = (.contactInvite, .commit, .pendingConfirmation, .press, AXRole.button)
        }
        guard let candidateKind = descriptor.3.candidateKind else {
            throw AIPlannerVisionError.invalidGoal
        }
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var frozenSettings = expectedSettings
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            let round = try observe()
            guard case .control(let purpose) = round.goal,
                  purpose == descriptor.0 || (stage == .inviteConfirm && purpose == .contactSendVerification),
                  round.phase == descriptor.1, round.evidence == descriptor.2,
                  round.action == descriptor.3, round.eligible.count == 1,
                  try round.eligible[0].role() == descriptor.4 else {
                throw AIPlannerVisionError.invalidGoal
            }
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            try beforeRound()
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled,
                  frozenSettings == nil || frozenSettings == settings else {
                throw AIPlannerVisionError.disabled
            }
            frozenSettings = settings
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible[0].pid() == pid else {
                throw AIPlannerVisionError.staleView
            }
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid,
                expectedTitle: nil,
                allowedKinds: [candidateKind],
                eligibleHandles: [round.eligible[0].handle], capture: capture)
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            let context = try AIPlannerStepContext(method: .contactAdd,
                                                   allowedSteps: [.verify, .reobserve, .stop],
                                                   phase: descriptor.1, lastEvidence: descriptor.2,
                                                   goal: round.goal,
                                                   contactSource: stage == .sourceMatch ? round.contactSource : nil)
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            guard decision.candidateID == nil, context.allowedSteps.contains(decision.step) else {
                throw AIPlannerVisionError.invalidChoice
            }
            switch decision.step {
            case .verify: return (.verified, settings)
            case .stop: return (.stopped, settings)
            case .reobserve: continue
            default: throw AIPlannerVisionError.invalidChoice
            }
        }
        throw AIPlannerVisionError.timeout
    }

    /// Read-only observations immediately before this command presses its own
    /// Done button and after AX proves a new selected group row. The offered
    /// button/row is an image anchor only; no model operation can press it or
    /// turn an AX-unknown creation into success.
    public func observeGroupCreation(phase: AIPlannerPhase,
                                     expectedSettings: CloudVisionSettings? = nil,
                                     gate: () throws -> Void, observe: Observe,
                                     verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard phase == .prepare || phase == .verify,
              (1...6).contains(maxRounds), maxDuration.isFinite,
              maxDuration > 0, maxDuration <= 40 else {
            throw AIPlannerVisionError.invalidGoal
        }
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var frozenSettings = expectedSettings
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            let round = try observe()
            if phase == .prepare {
                guard case .control(.confirm) = round.goal,
                      round.action == .press,
                      round.evidence == .pendingConfirmation,
                      round.eligible.count == 1,
                      try round.eligible[0].role() == AXRole.button else {
                    throw AIPlannerVisionError.invalidGoal
                }
            } else {
                guard case .conversationRow = round.goal,
                      round.action == .selectRow,
                      round.evidence == .postconditionPresent,
                      round.eligible.count == 1,
                      try round.eligible[0].role() == AXRole.row else {
                    throw AIPlannerVisionError.invalidGoal
                }
            }
            guard round.phase == phase else { throw AIPlannerVisionError.invalidGoal }
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            try beforeRound()
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled,
                  frozenSettings == nil || frozenSettings == settings else {
                throw AIPlannerVisionError.disabled
            }
            frozenSettings = settings
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible[0].pid() == pid else {
                throw AIPlannerVisionError.staleView
            }
            let kind: AIPlannerCandidateKind = phase == .prepare ? .press : .selectRow
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid,
                expectedTitle: round.expectedTitle, allowedKinds: [kind],
                eligibleHandles: [round.eligible[0].handle], capture: capture)
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            let context = try AIPlannerStepContext(method: .groupCreate,
                                                   allowedSteps: [.verify, .reobserve, .stop],
                                                   phase: phase, lastEvidence: round.evidence,
                                                   goal: round.goal)
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            guard decision.candidateID == nil,
                  context.allowedSteps.contains(decision.step) else {
                throw AIPlannerVisionError.invalidChoice
            }
            switch decision.step {
            case .verify: return (.verified, settings)
            case .stop: return (.stopped, settings)
            case .reobserve: continue
            default: throw AIPlannerVisionError.invalidChoice
            }
        }
        throw AIPlannerVisionError.timeout
    }

    private func observeStagingField(method: RPCMethod, phase: AIPlannerPhase,
                                     expectedSettings: CloudVisionSettings?,
                                     purpose: AIPlannerControlPurpose, role: String,
                                     gate: () throws -> Void, observe: Observe,
                                     verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard phase == .prepare || phase == .verify,
              (1...6).contains(maxRounds), maxDuration.isFinite,
              maxDuration > 0, maxDuration <= 40 else {
            throw AIPlannerVisionError.invalidGoal
        }
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var frozenSettings = expectedSettings
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            let round = try observe()
            guard case .control(let roundPurpose) = round.goal,
                  roundPurpose == purpose,
                  round.phase == phase, round.action == .writeText,
                  round.eligible.count == 1,
                  round.evidence == (phase == .prepare ? .inputReady : .postconditionPresent),
                  try round.eligible[0].role() == role else {
                throw AIPlannerVisionError.invalidGoal
            }
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            try beforeRound()
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled,
                  frozenSettings == nil || frozenSettings == settings else {
                throw AIPlannerVisionError.disabled
            }
            frozenSettings = settings
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible[0].pid() == pid else {
                throw AIPlannerVisionError.staleView
            }
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid,
                expectedTitle: round.expectedTitle, allowedKinds: [.writeText],
                eligibleHandles: [round.eligible[0].handle], capture: capture)
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            let context = try AIPlannerStepContext(method: method,
                                                   allowedSteps: [.verify, .reobserve, .stop],
                                                   phase: phase, lastEvidence: round.evidence,
                                                   goal: round.goal)
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            // Reject invalid model choices before a stale UI can mask them.
            guard decision.candidateID == nil, context.allowedSteps.contains(decision.step) else {
                throw AIPlannerVisionError.invalidChoice
            }
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            switch decision.step {
            case .verify:
                return (.verified, settings)
            case .stop:
                return (.stopped, settings)
            case .reobserve:
                continue
            default:
                throw AIPlannerVisionError.invalidChoice
            }
        }
        throw AIPlannerVisionError.timeout
    }

    /// A read-only check of the AX-proven pending card's 接受 button, followed
    /// (only after that press) by the newly opened remark popover's 完成 button.
    /// This entry offers no model-selected AX action. The caller owns both
    /// checkpoints, both presses, and the eventual added-card evidence.
    public func observeContactAcceptControl(phase: AIPlannerPhase,
                                            expectedSettings: CloudVisionSettings? = nil,
                                            gate: () throws -> Void, observe: Observe,
                                            verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard phase == .prepare || phase == .commit,
              (1...6).contains(maxRounds), maxDuration.isFinite,
              maxDuration > 0, maxDuration <= 40 else {
            throw AIPlannerVisionError.invalidGoal
        }
        let purpose: AIPlannerControlPurpose = phase == .prepare ? .requestAcceptButton : .requestRemarkDone
        let evidence: AIPlannerEvidence = phase == .prepare ? .targetVisible : .pendingConfirmation
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var frozenSettings = expectedSettings
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            let round = try observe()
            guard case .control(let roundPurpose) = round.goal,
                  roundPurpose == purpose,
                  round.phase == phase, round.action == .press,
                  round.eligible.count == 1, round.evidence == evidence,
                  try round.eligible[0].role() == AXRole.button else {
                throw AIPlannerVisionError.invalidGoal
            }
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            try beforeRound()
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled,
                  frozenSettings == nil || frozenSettings == settings else {
                throw AIPlannerVisionError.disabled
            }
            frozenSettings = settings
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible[0].pid() == pid else {
                throw AIPlannerVisionError.staleView
            }
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid,
                expectedTitle: nil, allowedKinds: [.press],
                eligibleHandles: [round.eligible[0].handle], capture: capture)
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            let context = try AIPlannerStepContext(method: .contactRequestAccept,
                                                   allowedSteps: [.verify, .reobserve, .stop],
                                                   phase: phase, lastEvidence: evidence,
                                                   goal: round.goal)
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            guard decision.candidateID == nil, context.allowedSteps.contains(decision.step) else {
                throw AIPlannerVisionError.invalidChoice
            }
            switch decision.step {
            case .verify: return (.verified, settings)
            case .stop: return (.stopped, settings)
            case .reobserve: continue
            default: throw AIPlannerVisionError.invalidChoice
            }
        }
        throw AIPlannerVisionError.timeout
    }

    /// Only an explicit broadcast.confirm can observe its already AX-proven,
    /// globally unique msgid task. The model has no press step here: it may
    /// verify, request a fresh image, or stop. A post-press invocation is only
    /// useful while the same enabled button remains, and never proves success.
    public func observeBroadcastConfirmControl(phase: AIPlannerPhase,
                                               expectedSettings: CloudVisionSettings? = nil,
                                               gate: () throws -> Void, observe: Observe,
                                               verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard phase == .commit || phase == .verify,
              (1...6).contains(maxRounds), maxDuration.isFinite,
              maxDuration > 0, maxDuration <= 40 else {
            throw AIPlannerVisionError.invalidGoal
        }
        let evidence: AIPlannerEvidence = phase == .commit ? .pendingConfirmation : .submitted
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var frozenSettings = expectedSettings
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            let round = try observe()
            guard case .control(.broadcastSend) = round.goal,
                  round.phase == phase, round.action == .press,
                  round.eligible.count == 1, round.evidence == evidence,
                  try round.eligible[0].role() == AXRole.button else {
                throw AIPlannerVisionError.invalidGoal
            }
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            try beforeRound()
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled,
                  frozenSettings == nil || frozenSettings == settings else {
                throw AIPlannerVisionError.disabled
            }
            frozenSettings = settings
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible[0].pid() == pid else {
                throw AIPlannerVisionError.staleView
            }
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid,
                allowedKinds: [.press], eligibleHandles: [round.eligible[0].handle],
                capture: capture)
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            let context = try AIPlannerStepContext(method: .broadcastConfirm,
                                                   allowedSteps: [.verify, .reobserve, .stop],
                                                   phase: phase, lastEvidence: evidence,
                                                   goal: round.goal)
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            guard decision.candidateID == nil, context.allowedSteps.contains(decision.step) else {
                throw AIPlannerVisionError.invalidChoice
            }
            switch decision.step {
            case .verify: return (.verified, settings)
            case .stop: return (.stopped, settings)
            case .reobserve: continue
            default: throw AIPlannerVisionError.invalidChoice
            }
        }
        throw AIPlannerVisionError.timeout
    }

    /// Passive main-window observation around the fixed `client.navigate`
    /// Window-menu press. The offered selected AX row is only an image anchor;
    /// the model may verify, reobserve, or stop, and cannot select that row or
    /// choose a macOS menu item outside the captured window.
    public func observeNavigation(phase: AIPlannerPhase,
                                  expectedSettings: CloudVisionSettings? = nil,
                                  gate: () throws -> Void, observe: Observe,
                                  verify: () throws -> Bool) throws ->
        (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings) {
        guard phase == .prepare || phase == .verify,
              (1...6).contains(maxRounds), maxDuration.isFinite,
              maxDuration > 0, maxDuration <= 40 else {
            throw AIPlannerVisionError.invalidGoal
        }
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var frozenSettings = expectedSettings
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            let round = try observe()
            guard case .conversationRow = round.goal,
                  round.phase == phase, round.action == .selectRow,
                  round.eligible.count == 1,
                  round.evidence == (phase == .prepare ? .targetVisible : .postconditionPresent),
                  try round.eligible[0].role() == AXRole.row else {
                throw AIPlannerVisionError.invalidGoal
            }
            try withinBudget(started)
            try gate()
            guard try verify() else { throw AIPlannerVisionError.staleView }
            try beforeRound()
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled,
                  frozenSettings == nil || frozenSettings == settings else {
                throw AIPlannerVisionError.disabled
            }
            frozenSettings = settings
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible[0].pid() == pid else {
                throw AIPlannerVisionError.staleView
            }
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid,
                expectedTitle: round.expectedTitle, allowedKinds: [.selectRow],
                eligibleHandles: [round.eligible[0].handle], capture: capture)
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            let context = try AIPlannerStepContext(method: .clientNavigate,
                                                   allowedSteps: [.verify, .reobserve, .stop],
                                                   phase: phase, lastEvidence: round.evidence,
                                                   goal: round.goal)
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            try withinBudget(started)
            try gate()
            guard try verify(), try settingsProvider() == settings else {
                throw AIPlannerVisionError.staleView
            }
            guard decision.candidateID == nil, context.allowedSteps.contains(decision.step) else {
                throw AIPlannerVisionError.invalidChoice
            }
            switch decision.step {
            case .verify:
                return (.verified, settings)
            case .stop:
                return (.stopped, settings)
            case .reobserve:
                continue
            default:
                throw AIPlannerVisionError.invalidChoice
            }
        }
        throw AIPlannerVisionError.timeout
    }

    private func runRounds(method: RPCMethod,
                           permitted: (AIPlannerReversibleRound, Bool) -> Bool,
                           requireVisualPostcondition: Bool,
                           gate: () throws -> Void, observe: Observe, apply: Apply,
                           verify: () throws -> Bool) throws -> AIPlannerReversibleOutcome {
        // Only the two read-only navigation methods get the longer AX budget.
        // Every other method, including contact.request.accept, keeps its
        // existing 40 s ceiling (and the header-press entries keep 24 s).
        let durationCeiling: TimeInterval = [.messageHistory, .contactList, .contactRequestList].contains(method) ? 60 : 40
        guard (1...6).contains(maxRounds), (1...maxRounds).contains(maxActions),
              maxDuration.isFinite, maxDuration > 0, maxDuration <= durationCeiling else {
            throw AIPlannerVisionError.invalidGoal
        }
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        func checkedVerify() throws -> Bool {
            let present = try verify()
            // AX reads can themselves block for seconds. A successful read
            // after the deadline must not turn into a successful command.
            try withinBudget(started)
            return present
        }
        var actions = 0
        // Once the AX postcondition has appeared, a model verification round
        // cannot cause another AX mutation even if the client changes again.
        var awaitingVisualPostcondition = false
        for _ in 0..<maxRounds {
            try withinBudget(started)
            try gate()
            let postconditionPresent = try checkedVerify()
            if postconditionPresent {
                if !requireVisualPostcondition { return .verified }
                awaitingVisualPostcondition = true
            } else if awaitingVisualPostcondition {
                return .unverified
            }
            let round = try observe()
            guard permitted(round, awaitingVisualPostcondition),
                  let kind = round.action.candidateKind,
                  (1...64).contains(round.eligible.count) else {
                throw AIPlannerVisionError.invalidGoal
            }
            let handles = Set(round.eligible.map(\.handle))
            guard handles.count == round.eligible.count else { throw AIPlannerVisionError.invalidCandidates }
            let context = try AIPlannerStepContext(method: method,
                                                   allowedSteps: awaitingVisualPostcondition
                                                       ? [.verify, .reobserve, .stop]
                                                       : [round.action, .reobserve, .verify, .stop],
                                                   phase: awaitingVisualPostcondition ? .verify : round.phase,
                                                   lastEvidence: awaitingVisualPostcondition
                                                       ? .postconditionPresent : round.evidence,
                                                   goal: round.goal)
            // AX observation can block. Do not capture the window if the command
            // budget, target, pause state or policy changed during that read.
            try withinBudget(started)
            try gate()
            let postconditionBeforeCapture = try checkedVerify()
            if awaitingVisualPostcondition {
                if !postconditionBeforeCapture { return .unverified }
            } else if postconditionBeforeCapture {
                if !requireVisualPostcondition { return .verified }
                awaitingVisualPostcondition = true
                continue
            }
            try beforeRound() // The owning handler may charge a command-wide inference budget.
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled else { throw AIPlannerVisionError.disabled }
            try withinBudget(started)
            try gate()
            let pid = try round.window.pid()
            guard pid > 0, try round.eligible.allSatisfy({ try $0.pid() == pid }) else {
                throw AIPlannerVisionError.staleView
            }
            let observation = try AIPlannerObservation.capture(
                window: round.window, expectedPID: pid, expectedTitle: round.expectedTitle,
                allowedKinds: [kind], eligibleHandles: handles, capture: capture
            )
            // Capture itself may block; no image leaves the process after a
            // deadline or a local grant/command gate change during capture.
            try withinBudget(started)
            try gate()
            guard try settingsProvider() == settings else { throw AIPlannerVisionError.disabled }
            let postconditionAfterCapture = try checkedVerify()
            if awaitingVisualPostcondition {
                if !postconditionAfterCapture { return .unverified }
            } else if postconditionAfterCapture {
                if !requireVisualPostcondition { return .verified }
                awaitingVisualPostcondition = true
                continue
            }
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            try withinBudget(started)
            try gate()
            guard try settingsProvider() == settings else { throw AIPlannerVisionError.disabled }
            guard context.allowedSteps.contains(decision.step) else { throw AIPlannerVisionError.invalidChoice }
            if awaitingVisualPostcondition {
                guard decision.candidateID == nil else { throw AIPlannerVisionError.invalidChoice }
                switch decision.step {
                case .verify:
                    return try checkedVerify() ? .verified : .unverified
                case .reobserve:
                    guard try checkedVerify() else { return .unverified }
                    continue
                case .stop:
                    return .stopped
                default:
                    throw AIPlannerVisionError.invalidChoice
                }
            }
            switch decision.step {
            case .stop:
                guard decision.candidateID == nil else { throw AIPlannerVisionError.invalidChoice }
                return .stopped
            case .reobserve, .verify:
                guard decision.candidateID == nil else { throw AIPlannerVisionError.invalidChoice }
                if decision.step == .verify {
                    try gate()
                    if try checkedVerify() {
                        if !requireVisualPostcondition { return .verified }
                        awaitingVisualPostcondition = true
                    }
                }
            default:
                guard decision.step == round.action,
                      let candidate = try decision.revalidatedCandidate(observation: observation,
                                                                         window: round.window),
                      handles.contains(candidate.element.handle) else {
                    throw AIPlannerVisionError.invalidChoice
                }
                // A local full-window disable or provider/key change while the
                // request was in flight revokes this model answer for AX writes.
                guard try settingsProvider() == settings else { throw AIPlannerVisionError.disabled }
                try gate() // Policy or pause state may have changed during the model request.
                if try checkedVerify() {
                    if !requireVisualPostcondition { return .verified }
                    awaitingVisualPostcondition = true
                    continue // A late client update needs no second action.
                }
                try withinBudget(started)
                try apply(decision.step, candidate.element)
                actions += 1
                // WeCom can apply AXSelectedRows before its conversation header
                // changes. Wait briefly for AX proof without another screenshot.
                if try settlePostcondition(started: started, verify: verify) {
                    if !requireVisualPostcondition { return .verified }
                    awaitingVisualPostcondition = true
                    continue
                }
                if actions >= maxActions { return .unverified }
            }
        }
        if awaitingVisualPostcondition { return .unverified }
        throw AIPlannerVisionError.timeout
    }

    private func withinBudget(_ started: TimeInterval) throws {
        let current = now()
        guard current.isFinite, current - started < maxDuration else {
            throw AIPlannerVisionError.timeout
        }
    }

    private func settlePostcondition(started: TimeInterval, verify: () throws -> Bool) throws -> Bool {
        for attempt in 0..<16 {
            try withinBudget(started)
            let present = try verify()
            try withinBudget(started)
            if present { return true }
            if attempt < 15 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return false
    }
}
