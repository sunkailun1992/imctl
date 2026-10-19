import Foundation
import ControlCore
import Testing
@testable import WeComAdapter

/// Opt-in network smoke test with a generated fixture image. It never captures
/// a real client window and never prints the local key or provider response.
@Suite("AI planner selected provider live smoke")
struct AIPlannerLiveProviderTests {
    @Test func selectedProviderAcceptsBoundedVisualStep() throws {
        guard ProcessInfo.processInfo.environment["IMCTL_LIVE_VISION"] == "1" else { return }
        var settings = try CloudVisionSettings.loadOrDefault()
        if let name = ProcessInfo.processInfo.environment["IMCTL_LIVE_VISION_PROVIDER"],
           let provider = CloudVisionProvider(rawValue: name) {
            try settings.setProvider(provider)
        }
        let (fake, window) = AIPlannerObservationTests.fixture()
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, allowedKinds: [.press],
            capture: { _, _ in AIPlannerObservationTests.shot() }
        )
        let context = try AIPlannerStepContext(
            method: .messageSend, allowedSteps: [.press, .stop],
            phase: .choose, lastEvidence: .targetVisible, goal: .control(.sendButton)
        )
        let client = AIPlannerStepClient()
        let decision = try client.decide(
            observation: observation, context: context, settings: settings
        )
        #expect([AIPlannerStep.press, .stop].contains(decision.step))
    }
}
