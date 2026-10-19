import AXKit
import ControlCore
import Foundation
import Testing
@testable import WeComAdapter

@Suite("AI planner bounded next-step decisions")
struct AIPlannerStepDecisionTests {
    static func fixture() throws -> (FakeAXBackend, AXElement, AIPlannerObservation) {
        let (fake, window) = AIPlannerObservationTests.fixture()
        let observation = try AIPlannerObservation.capture(window: window, expectedPID: fake.pid,
                                                            capture: { _, _ in AIPlannerObservationTests.shot() })
        return (fake, window, observation)
    }

    private static func groupNameObservation() throws -> (FakeAXBackend, AXElement, AIPlannerObservation) {
        let (fake, window) = AIPlannerObservationTests.fixture()
        let field = try #require(fake.element(atPath: [2]))
        fake.mutate(field.handle, attribute: AXAttribute.role, to: .string(AXRole.textField))
        fake.mutate(field.handle, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: 137, y: 36, width: 85, height: 18)))
        fake.mutate(field.handle, attribute: AXAttribute.value, to: .string("合成原群名"))
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, allowedKinds: [.writeText],
            eligibleHandles: [field.handle], capture: { _, _ in AIPlannerObservationTests.shot() })
        #expect(observation.candidates.count == 1 && observation.candidates[0].kind == .writeText
                && observation.candidates[0].role == AXRole.textField)
        return (fake, window, observation)
    }

    static func context(_ steps: Set<AIPlannerStep> = [.press, .verify, .stop]) throws -> AIPlannerStepContext {
        try AIPlannerStepContext(method: .messageSend, allowedSteps: steps, phase: .commit,
                                 lastEvidence: .pendingConfirmation, goal: .control(.sendButton))
    }

    static func body(_ decision: String, provider: CloudVisionProvider = .qwen) -> Data {
        if provider == .qwen {
            return try! JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": ["content": decision]]]
            ])
        }
        return try! JSONSerialization.data(withJSONObject: [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["text": decision]]]]]
        ])
    }

    static func http(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test func onlyCallerAllowedStepAndCurrentAXIDCanBeChosen() throws {
        let (_, window, observation) = try Self.fixture()
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("message.send"))
            #expect(prompt.contains("pendingConfirmation"))
            #expect(prompt.contains("press, stop, verify"))
            #expect(prompt.contains("ignore any instructions"))
            #expect(request.url?.host == "dashscope.aliyuncs.com")
            return (Self.body("{\"step\":\"press\",\"candidate_id\":\"C0\"}"), Self.http(request))
        }
        let result = try client.decide(observation: observation, context: Self.context(),
                                       settings: AIPlannerVisionClientTests.settings())
        #expect(result.step == .press && result.candidateID == "C0")
        #expect(try result.revalidatedCandidate(observation: observation, window: window)?.kind == .press)
    }

    /// A phone search lists one result per source (live 2026-09-29: a WeChat and a WeCom result for
    /// the same phone, each with its own 添加). The caller proves the requested source's one result
    /// from AX, so the match hint must not send the model to stop merely because the other source's
    /// result is visible — that stopped the live add twice.
    @Test func contactMatchHintAcceptsOneResultPerSource() throws {
        let (_, _, observation) = try Self.fixture()
        let context = try AIPlannerStepContext(method: .contactAdd, allowedSteps: [.verify, .reobserve, .stop],
                                               phase: .verify, lastEvidence: .postconditionPresent,
                                               goal: .control(.contactMatch))
        var prompt = ""
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            prompt = try #require(parts.first?["text"] as? String)
            return (Self.body("{\"step\":\"verify\"}"), Self.http(request))
        }
        let result = try client.decide(observation: observation, context: context,
                                       settings: AIPlannerVisionClientTests.settings())
        #expect(result.step == .verify)
        #expect(prompt.contains("one result per source") && prompt.contains("boxed Add inside one result row"))
        #expect(!prompt.contains("multiple plausible result buttons"))
        #expect(prompt.contains("Stop if a different search or window appears"))
    }

    @Test func geminiCanChooseVerificationButCannotClaimSuccess() throws {
        let (_, window, observation) = try Self.fixture()
        let client = AIPlannerStepClient { request in
            #expect(request.url?.host == "generativelanguage.googleapis.com")
            return (Self.body("{\"step\":\"verify\"}", provider: .gemini), Self.http(request))
        }
        let result = try client.decide(observation: observation, context: Self.context(),
                                       settings: AIPlannerVisionClientTests.settings(.gemini))
        #expect(result == AIPlannerStepDecision(step: .verify, candidateID: nil))
        #expect(try result.revalidatedCandidate(observation: observation, window: window) == nil)
    }

    @Test func exactAXConversationEvidencePrefersItsOnlyVisibleRowWithoutBypassingChoice() throws {
        let (fake, window, full) = try Self.fixture()
        let row = try #require(full.candidates.first { $0.kind == .selectRow })
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, allowedKinds: [.selectRow],
            eligibleHandles: [row.element.handle], capture: { _, _ in AIPlannerObservationTests.shot() }
        )
        #expect(observation.candidates.count == 1)
        let context = try AIPlannerStepContext(
            method: .conversationRead, allowedSteps: [.selectRow, .reobserve, .stop],
            phase: .locate, lastEvidence: .exactTargetRowVisible,
            goal: .conversationRow(title: "测试会话")
        )
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("exactTargetRowVisible"))
            #expect(prompt.contains("exactly one visible row whose own AX title exactly matches"))
            #expect(prompt.contains("choose selectRow with candidate_id C0"))
            #expect(prompt.contains("The caller will recheck the AX title, window, policy, and postcondition"))
            return (Self.body("{\"step\":\"stop\"}"), Self.http(request))
        }
        // Guidance does not turn the local AX match into an automatic action.
        let decision = try client.decide(observation: observation, context: context,
                                         settings: AIPlannerVisionClientTests.settings())
        #expect(decision == AIPlannerStepDecision(step: .stop, candidateID: nil))

        let missingAXTitle = try AIPlannerStepContext(
            method: .conversationRead, allowedSteps: [.selectRow, .stop],
            phase: .locate, lastEvidence: .targetVisible,
            goal: .conversationRow(title: "测试会话")
        )
        let cautious = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("A single offered candidate by itself is not proof of a title match"))
            #expect(!prompt.contains("choose selectRow with candidate_id C0"))
            return (Self.body("{\"step\":\"stop\"}"), Self.http(request))
        }
        #expect(try cautious.decide(observation: observation, context: missingAXTitle,
                                   settings: AIPlannerVisionClientTests.settings()).step == .stop)
    }

    @Test func freshConversationVerificationRequestsIndependentAXCheck() throws {
        let (_, _, observation) = try Self.fixture()
        let context = try AIPlannerStepContext(
            method: .conversationRead, allowedSteps: [.verify, .reobserve, .stop],
            phase: .verify, lastEvidence: .postconditionPresent,
            goal: .conversationRow(title: "测试会话")
        )
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("fresh image is consistent with that active conversation, choose verify"))
            #expect(prompt.contains("independent AX postcondition check"))
            #expect(prompt.contains("never claim success"))
            return (Self.body("{\"step\":\"verify\"}"), Self.http(request))
        }
        #expect(try client.decide(observation: observation, context: context,
                                  settings: AIPlannerVisionClientTests.settings()).step == .verify)
    }

    @Test func navigationPromptUsesAXProvenSelectionAsPassiveImageAnchorInBothRounds() throws {
        let (fake, window, full) = try Self.fixture()
        let row = try #require(full.candidates.first { $0.kind == .selectRow })
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, allowedKinds: [.selectRow],
            eligibleHandles: [row.element.handle], capture: { _, _ in AIPlannerObservationTests.shot() }
        )
        for (phase, evidence) in [
            (AIPlannerPhase.prepare, AIPlannerEvidence.targetVisible),
            (.verify, .postconditionPresent),
        ] {
            let context = try AIPlannerStepContext(
                method: .clientNavigate, allowedSteps: [.verify, .reobserve, .stop],
                phase: phase, lastEvidence: evidence,
                goal: .conversationRow(title: "测试会话")
            )
            let client = AIPlannerStepClient { request in
                let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                let messages = try #require(body["messages"] as? [[String: Any]])
                let parts = try #require(messages.first?["content"] as? [[String: Any]])
                let prompt = try #require(parts.first?["text"] as? String)
                #expect(prompt.contains("Read-only AX anchor box"))
                #expect(prompt.contains("exactly one sidebar row is AX-selected"))
                #expect(prompt.lowercased().contains("unreadable title text alone is not a contradiction"))
                #expect(prompt.contains("Allowed next steps are only: reobserve, stop, verify"))
                #expect(!prompt.contains("Actionable AX candidate boxes"))
                #expect(!prompt.contains("A single offered candidate by itself is not proof"))
                if phase == .verify {
                    #expect(prompt.contains("changed active AX conversation title"))
                    #expect(prompt.contains("check the same AX title and selected row again"))
                } else {
                    #expect(prompt.contains("Before the caller presses its fixed Window-menu item"))
                }
                return (Self.body("{\"step\":\"stop\"}"), Self.http(request))
            }
            // The clearer AX evidence still lets the model veto a conflict.
            let decision = try client.decide(observation: observation, context: context,
                                             settings: AIPlannerVisionClientTests.settings())
            #expect(decision == AIPlannerStepDecision(step: .stop, candidateID: nil))
        }
    }

    @Test func groupNamePromptKeepsBothObservationRoundsPassiveAndScopedToTheHeader() throws {
        let (fake, _, observation) = try Self.groupNameObservation()
        for provider in [CloudVisionProvider.qwen, .gemini] {
            for (phase, evidence) in [(AIPlannerPhase.prepare, AIPlannerEvidence.inputReady),
                                      (.verify, .postconditionPresent)] {
                let context = try AIPlannerStepContext(
                    method: .groupRename, allowedSteps: [.verify, .reobserve, .stop],
                    phase: phase, lastEvidence: evidence, goal: .control(.groupNameField))
                var calls = 0
                let client = AIPlannerStepClient { request in
                    calls += 1
                    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                    let prompt: String
                    if provider == .qwen {
                        let messages = try #require(body["messages"] as? [[String: Any]])
                        let parts = try #require(messages.first?["content"] as? [[String: Any]])
                        prompt = try #require(parts.first?["text"] as? String)
                        let image = try #require(parts.last?["image_url"] as? [String: Any])
                        #expect((image["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
                    } else {
                        let contents = try #require(body["contents"] as? [[String: Any]])
                        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
                        prompt = try #require(parts.first?["text"] as? String)
                        let image = try #require(parts.last?["inline_data"] as? [String: Any])
                        #expect(image["mime_type"] as? String == "image/jpeg")
                    }
                    let lower = prompt.lowercased()
                    #expect(prompt.contains("group.rename") && prompt.contains("Current phase is \(phase.rawValue)"))
                    #expect(prompt.contains("Allowed next steps are only: reobserve, stop, verify"))
                    #expect(lower.contains("read-only") && lower.contains("observation anchor"))
                    #expect(!prompt.contains("Actionable AX candidate boxes"))
                    #expect(prompt.contains("\(observation.candidates[0].id) writeText ["))
                    #expect(lower.contains("capability") && lower.contains("cannot choose writetext"))
                    #expect(lower.contains("sidebar") && lower.contains("conversation messages")
                            && lower.contains("lower chat composer"))
                    #expect(lower.contains("normal") && lower.contains("alternative group-name editor"))
                    #expect(lower.contains("active group header") && lower.contains("conflicting dialog")
                            && lower.contains("stop"))
                    #expect(!prompt.contains("Stop if another group or editor is visibly apparent"))
                    #expect(!prompt.contains("A single offered candidate by itself is not proof"))
                    #expect(prompt.contains("never claim success"))
                    // Return a veto even for the clearer prompt: observation
                    // wording must not convert stop into a verification.
                    return (Self.body("{\"step\":\"stop\"}", provider: provider), Self.http(request))
                }
                let decision = try client.decide(observation: observation, context: context,
                                                 settings: AIPlannerVisionClientTests.settings(provider))
                #expect(decision == AIPlannerStepDecision(step: .stop, candidateID: nil) && calls == 1)
            }
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func groupNameObservationDecisionsKeepThePassiveStepAndNilCandidateContract() throws {
        let (fake, window, observation) = try Self.groupNameObservation()
        let candidateID = observation.candidates[0].id
        let invalid = [
            "{\"step\":\"writeText\",\"candidate_id\":\"\(candidateID)\"}",
            "{\"step\":\"press\",\"candidate_id\":\"\(candidateID)\"}",
            "{\"step\":\"verify\",\"candidate_id\":\"\(candidateID)\"}",
            "{\"step\":\"reobserve\",\"candidate_id\":\"\(candidateID)\"}",
            "{\"step\":\"stop\",\"candidate_id\":\"\(candidateID)\"}",
            "{\"step\":\"verify\",\"candidate_id\":null}",
            "{\"step\":\"verify\",\"x\":170,\"y\":20}",
            "{\"step\":\"verify\",\"reason\":\"synthetic extra field\"}",
        ]
        for provider in [CloudVisionProvider.qwen, .gemini] {
            for (phase, evidence) in [(AIPlannerPhase.prepare, AIPlannerEvidence.inputReady),
                                      (.verify, .postconditionPresent)] {
                let context = try AIPlannerStepContext(
                    method: .groupRename, allowedSteps: [.verify, .reobserve, .stop],
                    phase: phase, lastEvidence: evidence, goal: .control(.groupNameField))
                #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                for step in [AIPlannerStep.verify, .reobserve, .stop] {
                    var calls = 0
                    let client = AIPlannerStepClient { request in
                        calls += 1
                        return (Self.body("{\"step\":\"\(step.rawValue)\"}", provider: provider), Self.http(request))
                    }
                    let decision = try client.decide(observation: observation, context: context,
                                                     settings: AIPlannerVisionClientTests.settings(provider))
                    #expect(decision == AIPlannerStepDecision(step: step, candidateID: nil) && calls == 1)
                    #expect(try decision.revalidatedCandidate(observation: observation, window: window) == nil)
                }
                for output in invalid {
                    var calls = 0
                    let client = AIPlannerStepClient { request in
                        calls += 1
                        return (Self.body(output, provider: provider), Self.http(request))
                    }
                    #expect(throws: AIPlannerVisionError.invalidChoice) {
                        try client.decide(observation: observation, context: context,
                                          settings: AIPlannerVisionClientTests.settings(provider))
                    }
                    #expect(calls == 1)
                }
            }
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func groupNameObservationWordingDoesNotEscapeItsMethodPhaseOrPassiveScope() throws {
        let (fake, _, observation) = try Self.groupNameObservation()
        let passive: Set<AIPlannerStep> = [.verify, .reobserve, .stop]
        let cases: [(RPCMethod, AIPlannerPhase, AIPlannerEvidence, Set<AIPlannerStep>)] = [
            (.messageSend, .prepare, .inputReady, passive),
            (.groupCreate, .prepare, .inputReady, passive),
            (.groupRename, .locate, .targetVisible, passive),
            (.groupRename, .choose, .inputReady, passive),
            (.groupRename, .commit, .pendingConfirmation, passive),
            (.groupRename, .prepare, .inputReady, passive.union([.writeText])),
            (.groupRename, .verify, .postconditionPresent, passive.union([.writeText])),
        ]
        for provider in [CloudVisionProvider.qwen, .gemini] {
            for (method, phase, evidence, allowed) in cases {
                // These contexts are valid at the method ceiling; a shared UI
                // goal alone must not grant the B37 passive-observation wording.
                let context = try AIPlannerStepContext(
                    method: method, allowedSteps: allowed, phase: phase,
                    lastEvidence: evidence, goal: .control(.groupNameField))
                var calls = 0
                let client = AIPlannerStepClient { request in
                    calls += 1
                    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                    let prompt: String
                    if provider == .qwen {
                        let messages = try #require(body["messages"] as? [[String: Any]])
                        let parts = try #require(messages.first?["content"] as? [[String: Any]])
                        prompt = try #require(parts.first?["text"] as? String)
                    } else {
                        let contents = try #require(body["contents"] as? [[String: Any]])
                        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
                        prompt = try #require(parts.first?["text"] as? String)
                    }
                    #expect(prompt.contains("Actionable AX candidate boxes"))
                    #expect(!prompt.contains("Read-only AX observation anchor box"))
                    #expect(!prompt.contains("Normal sidebar conversation rows"))
                    #expect(!prompt.contains("not alternative group-name editors"))
                    #expect(!prompt.contains("local AX capability of this observation anchor"))
                    return (Self.body("{\"step\":\"stop\"}", provider: provider), Self.http(request))
                }
                let decision = try client.decide(observation: observation, context: context,
                                                 settings: AIPlannerVisionClientTests.settings(provider))
                #expect(decision == AIPlannerStepDecision(step: .stop, candidateID: nil) && calls == 1)
            }
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func exactNewCustomersAXEvidenceGuidesSelectionAndFreshVerification() throws {
        let (fake, window, full) = try Self.fixture()
        let row = try #require(full.candidates.first { $0.kind == .selectRow })
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, allowedKinds: [.selectRow],
            eligibleHandles: [row.element.handle], capture: { _, _ in AIPlannerObservationTests.shot() }
        )
        let locate = try AIPlannerStepContext(
            method: .contactRequestList, allowedSteps: [.selectRow, .reobserve, .stop],
            phase: .locate, lastEvidence: .exactNewCustomersRowVisible,
            goal: .control(.newCustomers)
        )
        let selector = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("exactNewCustomersRowVisible"))
            #expect(prompt.contains("exactly one visible, selectable Contacts outline row"))
            #expect(prompt.contains("right-pane header is excluded"))
            #expect(prompt.contains("choose selectRow with candidate_id C0"))
            #expect(prompt.contains("Small or unreadable text alone is not a contradiction"))
            #expect(prompt.contains("selected row and cards table"))
            return (Self.body("{\"step\":\"stop\"}"), Self.http(request))
        }
        // The hint does not force an action when the model rejects the image.
        #expect(try selector.decide(observation: observation, context: locate,
                                    settings: AIPlannerVisionClientTests.settings()).step == .stop)

        let uncertain = try AIPlannerStepContext(
            method: .contactRequestList, allowedSteps: [.selectRow, .stop],
            phase: .locate, lastEvidence: .targetVisible,
            goal: .control(.newCustomers)
        )
        let cautious = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("A single offered candidate by itself is not proof"))
            #expect(!prompt.contains("right-pane header is excluded"))
            return (Self.body("{\"step\":\"stop\"}"), Self.http(request))
        }
        #expect(try cautious.decide(observation: observation, context: uncertain,
                                    settings: AIPlannerVisionClientTests.settings()).step == .stop)

        let verify = try AIPlannerStepContext(
            method: .contactRequestList, allowedSteps: [.verify, .reobserve, .stop],
            phase: .verify, lastEvidence: .postconditionPresent,
            goal: .control(.newCustomers)
        )
        let verifier = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(parts.first?["text"] as? String)
            #expect(prompt.contains("exact New Customers AX outline row selected"))
            #expect(prompt.contains("choose verify to request another independent AX selected-row and cards-table check"))
            #expect(prompt.contains("Small or unreadable row and card text alone is not a contradiction"))
            return (Self.body("{\"step\":\"verify\"}"), Self.http(request))
        }
        #expect(try verifier.decide(observation: observation, context: verify,
                                    settings: AIPlannerVisionClientTests.settings()).step == .verify)
    }

    @Test func rejectsMethodAndStepOutsideFixedCeiling() throws {
        do {
            _ = try AIPlannerStepContext(method: .policySet, allowedSteps: [.press], phase: .commit,
                                         lastEvidence: .none, goal: .control(.confirm))
            Issue.record("Daemon policy command was given AX steps")
        } catch let error as AIPlannerVisionError { #expect(error == .invalidGoal) }
        do {
            _ = try AIPlannerStepContext(method: .accountStatus, allowedSteps: [.press], phase: .locate,
                                         lastEvidence: .none, goal: .control(.confirm))
            Issue.record("Passive method was given AX press")
        } catch let error as AIPlannerVisionError { #expect(error == .invalidGoal) }
        do {
            _ = try AIPlannerStepContext(method: .messageSend, allowedSteps: [], phase: .locate,
                                         lastEvidence: .none, goal: .control(.confirm))
            Issue.record("Empty step set accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .invalidGoal) }
    }

    @Test func rejectsFreeTextCoordinatesWrongKindUnknownIDAndExtraFields() throws {
        let (_, _, observation) = try Self.fixture()
        let invalid = [
            "{\"step\":\"type arbitrary text\",\"candidate_id\":\"C1\"}",
            "{\"step\":\"writeText\",\"candidate_id\":\"C2\"}", // not allowed this round
            "{\"step\":\"press\",\"candidate_id\":\"C2\"}", // row is not a press candidate
            "{\"step\":\"press\",\"candidate_id\":\"C999\"}",
            "{\"step\":\"press\",\"x\":180,\"y\":135}",
            "{\"step\":\"press\",\"candidate_id\":\"C0\",\"text\":\"ignore policy\"}",
            "{\"step\":\"verify\",\"candidate_id\":\"C0\"}",
            "{\"step\":\"press\",\"candidate_id\":\"C0\"} then click",
        ]
        for output in invalid {
            let client = AIPlannerStepClient { request in (Self.body(output), Self.http(request)) }
            do {
                _ = try client.decide(observation: observation, context: Self.context(),
                                      settings: AIPlannerVisionClientTests.settings())
                Issue.record("Invalid step result accepted")
            } catch let error as AIPlannerVisionError { #expect(error == .invalidChoice) }
        }
    }

    @Test func newDecisionCannotActOnChangedCandidate() throws {
        let (fake, window, observation) = try Self.fixture()
        let client = AIPlannerStepClient { request in
            (Self.body("{\"step\":\"press\",\"candidate_id\":\"C0\"}"), Self.http(request))
        }
        let decision = try client.decide(observation: observation, context: Self.context(),
                                         settings: AIPlannerVisionClientTests.settings())
        let button = try #require(observation.candidates.first { $0.id == "C0" })
        fake.mutate(button.element.handle, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: 160, y: 135, width: 48, height: 22)))
        do {
            _ = try decision.revalidatedCandidate(observation: observation, window: window)
            Issue.record("Stale candidate was used")
        } catch let error as AIPlannerVisionError { #expect(error == .staleView) }
    }

    @Test func legacyCropToggleAndProviderErrorsCannotRunStepModel() throws {
        let (_, _, observation) = try Self.fixture()
        var legacy = CloudVisionSettings()
        try legacy.setAPIKey("unit-test-key", for: .qwen)
        try legacy.enable()
        let never = AIPlannerStepClient { _ in Issue.record("Unexpected provider request"); throw AIPlannerVisionError.requestFailed }
        do {
            _ = try never.decide(observation: observation, context: Self.context(), settings: legacy)
            Issue.record("B16 crop toggle authorized full-window step")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        let timeout = AIPlannerStepClient { _ in throw URLError(.timedOut) }
        do {
            _ = try timeout.decide(observation: observation, context: Self.context(),
                                   settings: AIPlannerVisionClientTests.settings())
            Issue.record("Timeout was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
    }

    @Test func geminiRegionRefusalStopsStepDecisionWithoutRetry() throws {
        let (_, _, observation) = try Self.fixture()
        let refusal = Data(#"{"error":{"code":400,"status":"FAILED_PRECONDITION","message":"User location is not supported for the API use."}}"#.utf8)
        var calls = 0
        let client = AIPlannerStepClient { request in
            calls += 1
            return (refusal, Self.http(request, status: 400))
        }
        do {
            _ = try client.decide(observation: observation, context: Self.context(),
                                   settings: AIPlannerVisionClientTests.settings(.gemini))
            Issue.record("Gemini region refusal was accepted")
        } catch let error as AIPlannerVisionError {
            #expect(error == .providerRegionUnavailable)
            #expect(!error.localizedDescription.contains("User location is not supported"))
        }
        #expect(calls == 1)
    }

    static func prompt(goal: AIPlannerGoal, phase: AIPlannerPhase, evidence: AIPlannerEvidence,
                       source: AIPlannerContactSource? = nil) throws -> String {
        let (_, _, observation) = try Self.fixture()
        let context = try AIPlannerStepContext(method: .contactAdd, allowedSteps: [.verify, .reobserve, .stop],
                                               phase: phase, lastEvidence: evidence, goal: goal, contactSource: source)
        var prompt = ""
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            prompt = try #require(parts.first?["text"] as? String)
            return (Self.body("{\"step\":\"verify\"}"), Self.http(request))
        }
        _ = try client.decide(observation: observation, context: context, settings: AIPlannerVisionClientTests.settings())
        return prompt
    }

    /// B54: the standalone 发送验证申请 window has a prompt that matches what its image shows.
    @Test func theSendVerificationPromptMatchesItsStandaloneWindow() throws {
        let prompt = try Self.prompt(goal: .control(.contactSendVerification), phase: .commit, evidence: .pendingConfirmation)
        #expect(prompt.contains("standalone Send Verification Request window"))
        #expect(prompt.contains("This image shows only that window") && prompt.contains("are not needed"))
        #expect(prompt.contains("already a customer") && prompt.contains("cannot press it"))
        #expect(!prompt.contains("another dialog") && !prompt.contains("title match"))
    }

    /// The in-panel invite keeps its prompt word for word.
    @Test func theInPanelInvitePromptIsUnchanged() throws {
        let prompt = try Self.prompt(goal: .control(.contactInvite), phase: .commit, evidence: .pendingConfirmation)
        #expect(prompt.contains("A single offered candidate by itself is not proof of a title match. If its AX title has not been confirmed, use the image to distinguish the fixed target; stop if it remains ambiguous."))
        #expect(prompt.contains("The caller has independently proved one invitation confirmation tied to this command's chosen result and checked its fixed greeting. The offered button is an image anchor only. Choose verify if the image is consistent with that one invitation; you cannot press it, edit text, or claim that an invitation was sent. Stop if another dialog or multiple plausible confirmations appear."))
    }

    /// The result-row prompt names the chosen source when the caller gives one.
    @Test func theMatchPromptNamesTheChosenSource() throws {
        let wecom = try Self.prompt(goal: .control(.contactMatch), phase: .verify, evidence: .postconditionPresent, source: .wecom)
        #expect(wecom.contains("chosen result is the WeCom (企业微信) result"))
        let plain = try Self.prompt(goal: .control(.contactMatch), phase: .verify, evidence: .postconditionPresent)
        #expect(!plain.contains("chosen result is the"))
    }

    @Test func aContactSourceGoesOnlyWithTheMatchGoal() {
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try AIPlannerStepContext(method: .contactAdd, allowedSteps: [.verify, .reobserve, .stop], phase: .commit,
                                     lastEvidence: .pendingConfirmation, goal: .control(.contactInvite), contactSource: .wechat)
        }
    }
}
