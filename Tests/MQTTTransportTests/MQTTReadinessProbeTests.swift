import Foundation
import MQTTNIO
import Testing
@testable import MQTTTransport

@Suite("MQTT readiness probe")
struct MQTTReadinessProbeTests {
    struct Boom: Error {}

    @Test func theProbeTopicIsInsideTheControllersSubtree() {
        let s = MQTTSettings(host: "h", controllerID: "mac-1")
        #expect(s.readinessTopic == "im/mac-1/readiness" && s.readinessTopic.hasPrefix(s.ownTopicPrefix))
    }

    @Test func probeWaitReturnsTheCompletion() {
        let ok: Result<Int, Error>? = ProbeWait.wait(timeout: 1) { complete in DispatchQueue.global().async { complete(.success(7)) } }
        #expect((try? ok?.get()) == 7)
        let failed: Result<Int, Error>? = ProbeWait.wait(timeout: 1) { complete in complete(.failure(Boom())) }
        if case .failure? = failed {} else { Issue.record("expected a failure") }
    }

    @Test func probeWaitGivesUpAtTheTimeout() {
        let started = Date()
        let none: Result<Int, Error>? = ProbeWait.wait(timeout: 0.2) { _ in }
        #expect(none == nil && Date().timeIntervalSince(started) < 1)
    }

    @Test func publishErrorsMapToFixedCategories() {
        #expect(MQTTNIOLink.probeCategory(MQTTError.reasonError(.notAuthorized)) == "rejected")
        #expect(MQTTNIOLink.probeCategory(MQTTError.noConnection) == "notConnected")
        #expect(MQTTNIOLink.probeCategory(Boom()) == "network")
    }
}
