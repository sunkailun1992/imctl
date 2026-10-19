import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("AI planner bounded observation rounds")
struct AIPlannerRoundSelectorTests {
    static func fixture() throws -> (FakeAXBackend, AXElement, AXElement) {
        let (fake, window) = AIPlannerObservationTests.fixture()
        return (fake, window, try #require(fake.element(atPath: [1])))
    }

    static func alternateShot() -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        return WeComWindowScreenshot(image: context.makeImage()!,
                                     windowFrame: CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    static func select(_ selector: AIPlannerRoundSelector, window: AXElement,
                       eligible: AXElement) throws -> AIPlannerCandidate? {
        try selector.select(window: window, method: .messageSend, goal: .control(.sendButton),
                            allowedKinds: [.press], expectedTitle: nil, eligible: [eligible])
    }

    @Test func reobserveUsesFreshScreenshotThenSelectsOnlyEligibleCandidate() throws {
        let (_, window, button) = try Self.fixture()
        var rounds = 0
        var images: [Data] = []
        let selector = AIPlannerRoundSelector(
            maxRounds: 3,
            beforeRound: { rounds += 1 },
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                #expect(handles == [button.handle])
                return try AIPlannerObservation.capture(
                    window: window, expectedPID: pid, expectedTitle: title,
                    allowedKinds: kinds, eligibleHandles: handles,
                    capture: { _, _ in rounds == 1 ? AIPlannerObservationTests.shot() : Self.alternateShot() }
                )
            },
            decide: { observation, context, _ in
                #expect(observation.candidates.count == 1)
                #expect(context.allowedSteps == [.press, .reobserve, .stop])
                images.append(observation.imageJPEG)
                return rounds == 1
                    ? AIPlannerStepDecision(step: .reobserve, candidateID: nil)
                    : AIPlannerStepDecision(step: .press, candidateID: "C0")
            }
        )
        let selected = try Self.select(selector, window: window, eligible: button)
        #expect(selected?.element.handle == button.handle)
        #expect(rounds == 2 && images.count == 2 && images[0] != images[1])
    }

    @Test func stopReturnsNoCandidateOrAXAction() throws {
        let (_, window, button) = try Self.fixture()
        var screenshots = 0
        let selector = AIPlannerRoundSelector(
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                screenshots += 1
                return try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                        expectedTitle: title, allowedKinds: kinds,
                                                        eligibleHandles: handles,
                                                        capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        #expect(try Self.select(selector, window: window, eligible: button) == nil)
        #expect(screenshots == 1)
    }

    @Test func forgedCandidateIDFailsBeforeAction() throws {
        let (_, window, button) = try Self.fixture()
        let selector = AIPlannerRoundSelector(
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                 expectedTitle: title, allowedKinds: kinds,
                                                 eligibleHandles: handles,
                                                 capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in AIPlannerStepDecision(step: .press, candidateID: "C999") }
        )
        do {
            _ = try Self.select(selector, window: window, eligible: button)
            Issue.record("Unlisted candidate ID was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .invalidChoice) }
    }

    @Test func changedEligibleMeaningAcrossRoundsFailsBeforeSecondModelCall() throws {
        let (fake, window, button) = try Self.fixture()
        var rounds = 0
        var modelCalls = 0
        let selector = AIPlannerRoundSelector(
            beforeRound: {
                rounds += 1
                if rounds == 2 { fake.mutate(button.handle, attribute: AXAttribute.title, to: .string("取消")) }
            },
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                 expectedTitle: title, allowedKinds: kinds,
                                                 eligibleHandles: handles,
                                                 capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in
                modelCalls += 1
                return AIPlannerStepDecision(step: .reobserve, candidateID: nil)
            }
        )
        do {
            _ = try Self.select(selector, window: window, eligible: button)
            Issue.record("Changed control text was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .staleView) }
        #expect(rounds == 2 && modelCalls == 1)
    }

    @Test func roundAndTimeBudgetsStopWithoutExtraScreenshot() throws {
        let (_, window, button) = try Self.fixture()
        var captured = 0
        let observe: AIPlannerRoundSelector.Observe = { window, pid, title, kinds, handles in
            captured += 1
            return try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                    expectedTitle: title, allowedKinds: kinds,
                                                    eligibleHandles: handles,
                                                    capture: { _, _ in AIPlannerObservationTests.shot() })
        }
        let model: AIPlannerRoundSelector.Decide = { _, _, _ in
            AIPlannerStepDecision(step: .reobserve, candidateID: nil)
        }
        let roundBound = AIPlannerRoundSelector(maxRounds: 2,
                                               settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                               observe: observe, decide: model)
        do {
            _ = try Self.select(roundBound, window: window, eligible: button)
            Issue.record("Round budget was bypassed")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
        #expect(captured == 2)
        captured = 0
        var ticks = [0.0, 0.0, 61.0]
        let timeBound = AIPlannerRoundSelector(maxRounds: 3, maxDuration: 45,
                                              settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                              observe: observe, decide: model,
                                              now: { ticks.removeFirst() })
        do {
            _ = try Self.select(timeBound, window: window, eligible: button)
            Issue.record("Time budget was bypassed")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
        #expect(captured == 1)
    }

    @Test func legacyFullWindowGateRejectsBeforeAnyCapture() throws {
        let (_, window, button) = try Self.fixture()
        var settings = CloudVisionSettings()
        try settings.setAPIKey("unit-test-key", for: .qwen)
        try settings.enable()
        var captured = false
        let selector = AIPlannerRoundSelector(
            settingsProvider: { settings },
            observe: { _, _, _, _, _ in
                captured = true
                throw AIPlannerVisionError.captureUnavailable
            },
            decide: { _, _, _ in AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        do {
            _ = try Self.select(selector, window: window, eligible: button)
            Issue.record("Legacy crop authorization took a full screenshot")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        #expect(!captured)
    }

    @Test func providerRegionRefusalDoesNotTriggerAnotherRound() throws {
        let (_, window, button) = try Self.fixture()
        var captures = 0
        var decisions = 0
        let selector = AIPlannerRoundSelector(
            maxRounds: 4,
            settingsProvider: { try AIPlannerVisionClientTests.settings(.gemini) },
            observe: { window, pid, title, kinds, handles in
                captures += 1
                return try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                        expectedTitle: title, allowedKinds: kinds,
                                                        eligibleHandles: handles,
                                                        capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in
                decisions += 1
                throw AIPlannerVisionError.providerRegionUnavailable
            }
        )
        do {
            _ = try Self.select(selector, window: window, eligible: button)
            Issue.record("Gemini region refusal was retried")
        } catch let error as AIPlannerVisionError { #expect(error == .providerRegionUnavailable) }
        #expect(captures == 1 && decisions == 1)
    }

    @Test func localGrantRevokedAfterCapturePreventsModelUpload() throws {
        let (_, window, button) = try Self.fixture()
        var settings = try AIPlannerVisionClientTests.settings()
        var decisions = 0
        let selector = AIPlannerRoundSelector(
            settingsProvider: { settings },
            observe: { window, pid, title, kinds, handles in
                let observation = try AIPlannerObservation.capture(
                    window: window, expectedPID: pid, expectedTitle: title,
                    allowedKinds: kinds, eligibleHandles: handles,
                    capture: { _, _ in AIPlannerObservationTests.shot() })
                settings.disable()
                return observation
            },
            decide: { _, _, _ in decisions += 1; return AIPlannerStepDecision(step: .press, candidateID: "C0") }
        )
        #expect(throws: AIPlannerVisionError.disabled) {
            _ = try Self.select(selector, window: window, eligible: button)
        }
        #expect(decisions == 0)
    }

    @Test func localGrantRevokedDuringInferencePreventsChoice() throws {
        let (_, window, button) = try Self.fixture()
        var settings = try AIPlannerVisionClientTests.settings()
        let selector = AIPlannerRoundSelector(
            settingsProvider: { settings },
            observe: { window, pid, title, kinds, handles in
                try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                 expectedTitle: title, allowedKinds: kinds,
                                                 eligibleHandles: handles,
                                                 capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in
                settings.disable()
                return AIPlannerStepDecision(step: .press, candidateID: "C0")
            }
        )
        #expect(throws: AIPlannerVisionError.disabled) {
            _ = try Self.select(selector, window: window, eligible: button)
        }
    }

    @Test func commandGateRevokedDuringInferencePreventsChoice() throws {
        let (_, window, button) = try Self.fixture()
        var paused = false
        let selector = AIPlannerRoundSelector(
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                 expectedTitle: title, allowedKinds: kinds,
                                                 eligibleHandles: handles,
                                                 capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in
                paused = true
                return AIPlannerStepDecision(step: .press, candidateID: "C0")
            }
        )
        #expect(throws: AIPlannerVisionError.disabled) {
            _ = try selector.select(window: window, method: .messageSend,
                                    goal: .control(.sendButton), allowedKinds: [.press],
                                    expectedTitle: nil, eligible: [button],
                                    gate: { if paused { throw AIPlannerVisionError.disabled } })
        }
    }

    /// B54: the selector reports its model request like the runner does.
    @Test func aSelectorRoundIsReported() throws {
        let (_, window, button) = try Self.fixture()
        var records: [AIPlannerRoundRecord] = []
        var selector = AIPlannerRoundSelector(
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                 expectedTitle: title, allowedKinds: kinds,
                                                 eligibleHandles: handles,
                                                 capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        selector.roundSink = { records.append($0) }
        #expect(try Self.select(selector, window: window, eligible: button) == nil)
        #expect(records.count == 1 && records[0].outcome == "stop" && records[0].round == 1
                && records[0].goal == "sendButton" && records[0].method == .messageSend)
    }
}
