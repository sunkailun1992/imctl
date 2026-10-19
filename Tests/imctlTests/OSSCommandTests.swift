import Foundation
import Testing
@testable import imctl
@testable import OSSClient

// .serialized: two tests below swap OSSSetCommand.readSecretLine, a static var shared by the whole process;
// Swift Testing runs a suite's tests concurrently by default, which would race those swaps against each other.
@Suite("imctl oss", .serialized)
struct OSSCommandTests {
    @Test func setWritesPrivateSettingsAndStatusMasksTheKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-cli-\(UUID().uuidString)/oss.json").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: file).deletingLastPathComponent()) }
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--access-key-secret", "test-secret", "--view-expire", "600", "--max-upload", "1024", "--config", file]).run()
        let s = try OSSSettings.load(from: URL(fileURLWithPath: file))
        #expect(s.bucket == "photos" && s.accessKeySecret == "test-secret" && s.viewExpireSeconds == 600 && s.maxUploadBytes == 1024 && s.region == "cn-hangzhou")
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        let status = try OSSStatusCommand.parse(["--config", file]).collect()
        #expect(status["present"] as? Bool == true && (status["summary"] as? String)?.contains("test-secret") == false && (status["summary"] as? String)?.contains("TEST…01") == true)
        // an empty secret keeps the stored one
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--config", file]).run()
        #expect(try OSSSettings.load(from: URL(fileURLWithPath: file)).accessKeySecret == "test-secret")
        #expect(throws: (any Error).self) { try OSSSetCommand.parse(["--endpoint", "ftp://x", "--bucket", "b", "--base-dir", "d", "--access-key-id", "k", "--access-key-secret", "s"]).validate() }
        #expect(OSSCommand.configuration.subcommands.compactMap { $0.configuration.commandName } == ["set", "status", "test"])
    }

    /// `--secret-stdin` reads through `OSSSetCommand.readSecretLine`, a seam over the real `readLine()` so
    /// this doesn't have to touch the process's actual stdin.
    @Test func setReadsTheSecretFromStdinThroughTheReaderSeam() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-cli-\(UUID().uuidString)/oss.json").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: file).deletingLastPathComponent()) }
        let savedReader = OSSSetCommand.readSecretLine
        defer { OSSSetCommand.readSecretLine = savedReader }
        OSSSetCommand.readSecretLine = { "stdin-secret" }
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--secret-stdin", "--config", file]).run()
        #expect(try OSSSettings.load(from: URL(fileURLWithPath: file)).accessKeySecret == "stdin-secret")
    }

    /// `--secret-stdin` trims surrounding whitespace, same as a pasted line would carry.
    @Test func setTrimsWhitespaceFromTheStdinSecret() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-cli-\(UUID().uuidString)/oss.json").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: file).deletingLastPathComponent()) }
        let savedReader = OSSSetCommand.readSecretLine
        defer { OSSSetCommand.readSecretLine = savedReader }
        OSSSetCommand.readSecretLine = { "  padded-secret  " }
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--secret-stdin", "--config", file]).run()
        #expect(try OSSSettings.load(from: URL(fileURLWithPath: file)).accessKeySecret == "padded-secret")
    }

    /// `imctl oss status --json`'s printed text is the JSON `run()` actually emits (factored out of `run()`
    /// as `jsonText()` so this doesn't need to capture stdout); it must carry the masked summary but never
    /// the raw secret.
    @Test func statusJSONTextNeverCarriesTheSecret() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-cli-\(UUID().uuidString)/oss.json").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: file).deletingLastPathComponent()) }
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--access-key-secret", "do-not-print-this-secret", "--config", file]).run()
        let text = try OSSStatusCommand.parse(["--config", file, "--json"]).jsonText()
        #expect(!text.contains("do-not-print-this-secret"), "leaked the secret: \(text)")
        #expect(text.contains("TEST…01"))
        #expect(!text.contains("TESTAKID0000000001"), "raw AccessKeyId in status JSON")
        #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil, "not valid JSON: \(text)")
    }
}
