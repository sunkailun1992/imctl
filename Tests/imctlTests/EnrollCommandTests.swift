import ArgumentParser
import Foundation
import MQTTTransport
import Testing
@testable import imctl

@Suite("imctl enroll")
struct EnrollCommandTests {
    func tempConfig() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imctl-enroll-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mqtt.json")
    }

    /// Re-enrolling to change the broker keeps the controller id the Java side already sends to.
    @Test func withoutAnIDTheEnrolledOneIsKept() throws {
        let url = tempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try MQTTSettings(host: "broker-old.example.invalid", controllerID: "mac-01").save(to: url)
        try EnrollCommand.parse(["--broker", "broker-new.example.invalid", "--config", url.path]).run()
        let saved = try MQTTSettings.load(from: url)
        #expect(saved.controllerID == "mac-01" && saved.host == "broker-new.example.invalid")
    }

    @Test func withNothingEnrolledTheHostNameIsTheDefault() throws {
        let url = tempConfig()
        #expect(try EnrollCommand.resolvedControllerID(explicit: nil, settingsURL: url, localHostName: "Example-Mac").id == "example-mac")
        #expect(try EnrollCommand.resolvedControllerID(explicit: "mac-07", settingsURL: url, localHostName: "Example-Mac").id == "mac-07")
    }

    @Test func noHostNameAndNothingEnrolledAsksForAnID() {
        #expect(throws: ValidationError.self) {
            try EnrollCommand.resolvedControllerID(explicit: nil, settingsURL: tempConfig(), localHostName: nil)
        }
    }

    /// Review I1: a settings file that exists but cannot be read is not guessed over — a host-name id would move
    /// this Mac to another topic tree and the Java side's commands would reach nobody.
    @Test func anUnreadableSettingsFileIsNotGuessedOver() throws {
        let url = tempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: ValidationError.self) {
            try EnrollCommand.resolvedControllerID(explicit: nil, settingsURL: url, localHostName: "Example-Mac")
        }
        #expect(throws: (any Error).self) {
            try EnrollCommand.parse(["--broker", "broker-b52.example.invalid", "--config", url.path]).run()
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
        // Typing the id is the way out.
        #expect(try EnrollCommand.resolvedControllerID(explicit: "mac-01", settingsURL: url, localHostName: "Example-Mac").id == "mac-01")
    }

    @Test func anIDThatIsNotOneTopicLevelIsRefused() throws {
        let url = tempConfig()
        #expect(throws: (any Error).self) {
            try EnrollCommand.parse(["--broker", "broker-b52.example.invalid", "--controller-id", "a/b", "--config", url.path]).run()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
