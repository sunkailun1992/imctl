import Foundation
import Testing
@testable import MQTTTransport
@testable import imctl_console

/// B52 addendum: on a first MQTT setup the form needs only the broker; a saved id is never replaced.
@Suite("Console MQTT controller id")
@MainActor
struct ConsoleControllerIDTests {
    @Test func theFormOffersTheHostNameOnlyWhenNothingIsEnrolled() {
        var stored = ConsoleModel.StoredSettings()
        #expect(ConsoleModel.formControllerID(stored: stored, hostDefault: "example-mac", fileExists: false) == "example-mac")
        #expect(ConsoleModel.formControllerID(stored: stored, hostDefault: nil, fileExists: false) == "")
        // Review I1: mqtt.json is there but unreadable — no guess over the id the Java side uses.
        #expect(ConsoleModel.formControllerID(stored: stored, hostDefault: "example-mac", fileExists: true) == "")
        stored.controllerID = "mac-01"
        #expect(ConsoleModel.formControllerID(stored: stored, hostDefault: "example-mac", fileExists: true) == "mac-01")
    }

    @Test func anIDThatIsNotOneTopicLevelIsNotSaved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-console-id-\(UUID().uuidString).json")
        let model = ConsoleModel()
        model.saveMQTT(host: "broker-b52.example.invalid", port: 1883, tls: false, controllerID: "a/b", username: "", password: "",
                       topicPrefix: "im", to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.log.last?.isError == true && model.log.last?.title == "mqtt enroll")
    }
}
