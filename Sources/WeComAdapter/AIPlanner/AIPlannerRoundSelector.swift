import AXKit
import ControlCore
import Foundation

/// Runs bounded observation rounds for one already-authorized fixed command
/// step. This class only chooses an AX candidate; it never mutates the client
/// or treats a model's `verify` step as a successful command result.
public struct AIPlannerRoundSelector {
    public typealias Observe = (AXElement, pid_t, String?, Set<AIPlannerCandidateKind>, Set<AXElementHandle>) throws -> AIPlannerObservation
    public typealias Decide = (AIPlannerObservation, AIPlannerStepContext, CloudVisionSettings) throws -> AIPlannerStepDecision

    public let maxRounds: Int
    public let maxDuration: TimeInterval
    private let beforeRound: () throws -> Void
    private let settingsProvider: () throws -> CloudVisionSettings
    private let observe: Observe
    private let decide: Decide
    private let now: () -> TimeInterval
    /// B54: one fixed-category record per model request; the handler logs it and keeps the last.
    public var roundSink: ((AIPlannerRoundRecord) -> Void)?
    private let rounds = AIPlannerRoundCounter()

    public init(
        maxRounds: Int = 4,
        maxDuration: TimeInterval = 45,
        beforeRound: @escaping () throws -> Void = {},
        settingsProvider: @escaping () throws -> CloudVisionSettings = { try CloudVisionSettings.loadOrDefault() },
        observe: @escaping Observe = { window, pid, title, kinds, handles in
            try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                             expectedTitle: title, allowedKinds: kinds,
                                             eligibleHandles: handles)
        },
        decide: @escaping Decide = { observation, context, settings in
            try AIPlannerStepClient().decide(observation: observation, context: context, settings: settings)
        },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maxRounds = maxRounds
        self.maxDuration = maxDuration
        self.beforeRound = beforeRound
        self.settingsProvider = settingsProvider
        self.observe = observe
        self.decide = decide
        self.now = now
    }

    /// Returns one revalidated candidate or nil when the model chooses stop.
    /// The caller must still intersect the returned handle with the current
    /// method-specific eligible elements, perform its own AX action, and verify
    /// the postcondition. A fresh screenshot/model request occurs on reobserve.
    public func select(
        window: AXElement,
        method: RPCMethod,
        goal: AIPlannerGoal,
        allowedKinds: Set<AIPlannerCandidateKind>,
        expectedTitle: String?,
        eligible: [AXElement],
        phase: AIPlannerPhase = .choose,
        lastEvidence: AIPlannerEvidence = .targetVisible,
        gate: () throws -> Void = {}
    ) throws -> AIPlannerCandidate? {
        guard maxRounds > 0, maxRounds <= 8, maxDuration > 0, maxDuration <= 60,
              maxDuration.isFinite,
              allowedKinds.count == 1, let kind = allowedKinds.first,
              !eligible.isEmpty, eligible.count <= 64 else { throw AIPlannerVisionError.invalidGoal }
        let handles = Set(eligible.map(\.handle))
        guard handles.count == eligible.count else { throw AIPlannerVisionError.invalidCandidates }
        let step: AIPlannerStep
        switch kind {
        case .press: step = .press
        case .selectRow: step = .selectRow
        case .writeText: step = .writeText
        case .scroll: step = .scroll
        }
        let context = try AIPlannerStepContext(method: method, allowedSteps: [step, .reobserve, .stop],
                                               phase: phase, lastEvidence: lastEvidence, goal: goal)
        let expectedPID: pid_t
        do {
            expectedPID = try window.pid()
            guard expectedPID > 0,
                  try eligible.allSatisfy({ try $0.pid() == expectedPID }) else {
                throw AIPlannerVisionError.staleView
            }
        } catch { throw AIPlannerVisionError.staleView }
        let started = now()
        guard started.isFinite else { throw AIPlannerVisionError.timeout }
        var originalSemantics: [AXElementHandle: Data]?
        for _ in 0..<maxRounds {
            let currentTime = now()
            guard currentTime.isFinite, currentTime - started < maxDuration else {
                throw AIPlannerVisionError.timeout
            }
            try gate()
            try beforeRound() // The handler's global command budget belongs here.
            let settings = try settingsProvider()
            guard settings.fullWindowEnabled else { throw AIPlannerVisionError.disabled }
            let observation = try observe(window, expectedPID, expectedTitle, allowedKinds, handles)
            // Capture can block. Recheck the local grant and command gate before
            // pixels leave the process for the model.
            try gate()
            guard try settingsProvider() == settings else { throw AIPlannerVisionError.disabled }
            let afterCapture = now()
            guard afterCapture.isFinite, afterCapture - started < maxDuration else {
                throw AIPlannerVisionError.timeout
            }
            var currentSemantics: [AXElementHandle: Data] = [:]
            for candidate in observation.candidates {
                guard currentSemantics.updateValue(candidate.semanticDigest,
                                                   forKey: candidate.element.handle) == nil else {
                    throw AIPlannerVisionError.invalidCandidates
                }
            }
            guard Set(currentSemantics.keys) == handles else { throw AIPlannerVisionError.invalidCandidates }
            if let originalSemantics, originalSemantics != currentSemantics {
                throw AIPlannerVisionError.staleView
            }
            originalSemantics = currentSemantics
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
            // The model may take seconds. A pause, policy edit or provider/key
            // change during inference invalidates every response, including a
            // request to observe again.
            try gate()
            guard try settingsProvider() == settings else { throw AIPlannerVisionError.disabled }
            let afterDecision = now()
            guard afterDecision.isFinite, afterDecision - started < maxDuration else {
                throw AIPlannerVisionError.timeout
            }
            guard context.allowedSteps.contains(decision.step) else { throw AIPlannerVisionError.invalidChoice }
            switch decision.step {
            case .reobserve:
                guard decision.candidateID == nil else { throw AIPlannerVisionError.invalidChoice }
                continue
            case .stop:
                guard decision.candidateID == nil else { throw AIPlannerVisionError.invalidChoice }
                return nil
            default:
                guard decision.step == step,
                      let fresh = try decision.revalidatedCandidate(observation: observation, window: window),
                      handles.contains(fresh.element.handle) else { throw AIPlannerVisionError.invalidChoice }
                return fresh
            }
        }
        throw AIPlannerVisionError.timeout
    }
}
