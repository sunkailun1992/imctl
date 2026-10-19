import Foundation
import Testing
@testable import imctl
@testable import WeComAdapter

@Suite("imctl vision", .serialized)
struct CloudVisionCommandTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-vision-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(CloudVisionSettings.fileName)
    }

    @Test func defaultsAndModelAllowlist() throws {
        var settings = CloudVisionSettings()
        #expect(!settings.cloudEnabled)
        #expect(!settings.fullWindowEnabled)
        #expect(settings.provider == .qwen)
        #expect(settings.model == "qwen3.7-plus")
        #expect(!settings.keyPresent)
        #expect(CloudVisionSettings.allowedModels(for: .qwen) == ["qwen3.7-plus", "qwen3.8-flash", "qwen3.8-max", "qwen3-vl-plus", "qwen3-vl-flash"])
        #expect(CloudVisionSettings.allowedModels(for: .gemini) == ["gemini-3.8-flash", "gemini-3.7-flash"])
        #expect(CloudVisionSettings.allowedModels(for: .deepseek) == ["deepseek-flash"])
        #expect(throws: CloudVisionSettingsError.self) { try settings.setProvider(.qwen, model: "deepseek-flash") }
        #expect(throws: CloudVisionSettingsError.self) { try settings.enable() }
        try settings.setProvider(.qwen, model: "qwen3.8-flash")
        #expect(settings.model == "qwen3.8-flash")
    }

    @Test func setRotatesPerProviderAndStatusDoesNotRevealKeys() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = ["synthetic", "one"].joined(separator: "-")
        let replacement = ["synthetic", "two"].joined(separator: "-")
        let secondProvider = ["synthetic", "three"].joined(separator: "-")
        let oldReader = CloudVisionSetCommand.readSecretLine
        defer { CloudVisionSetCommand.readSecretLine = oldReader }

        CloudVisionSetCommand.readSecretLine = { first }
        try CloudVisionSetCommand.parse(["--secret-stdin", "--config", url.path]).run()
        var settings = try CloudVisionSettings.load(from: url)
        #expect(settings.cloudEnabled && settings.apiKey(for: .qwen) == first)
        #expect(!settings.fullWindowEnabled)
        try CloudVisionFullWindowCommand.parse(["--enable", "--config", url.path]).run()
        settings = try CloudVisionSettings.load(from: url)
        #expect(settings.fullWindowEnabled)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)

        CloudVisionSetCommand.readSecretLine = { replacement }
        try CloudVisionSetCommand.parse(["--provider", "qwen", "--secret-stdin", "--config", url.path]).run()
        settings = try CloudVisionSettings.load(from: url)
        #expect(settings.apiKey(for: .qwen) == replacement)

        CloudVisionSetCommand.readSecretLine = { secondProvider }
        try CloudVisionSetCommand.parse(["--provider", "gemini", "--secret-stdin", "--config", url.path]).run()
        settings = try CloudVisionSettings.load(from: url)
        #expect(settings.provider == .gemini && settings.model == "gemini-3.8-flash")
        #expect(settings.apiKey(for: .qwen) == replacement && settings.apiKey(for: .gemini) == secondProvider)
        let text = try CloudVisionStatusCommand.parse(["--config", url.path, "--json"]).jsonText()
        let status = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(status["keyPresent"] as? Bool == true)
        #expect(status["fullWindowEnabled"] as? Bool == true)
        #expect(!text.contains(first) && !text.contains(replacement) && !text.contains(secondProvider))
        #expect(!String(reflecting: settings).contains(secondProvider))

        try CloudVisionDisableCommand.parse(["--config", url.path]).run()
        settings = try CloudVisionSettings.load(from: url)
        #expect(!settings.cloudEnabled && !settings.fullWindowEnabled && settings.keyPresent(for: .gemini))
        try CloudVisionDeleteCommand.parse(["--provider", "gemini", "--config", url.path]).run()
        settings = try CloudVisionSettings.load(from: url)
        #expect(!settings.keyPresent(for: .gemini) && settings.keyPresent(for: .qwen))
        try CloudVisionDeleteCommand.parse(["--config", url.path]).run()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func malformedSettingsAndLooseModesFailClosed() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var settings = CloudVisionSettings()
        try settings.setAPIKey(["synthetic", "only"].joined(separator: "-"), for: .qwen)
        try settings.enable()
        try settings.save(to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: CloudVisionSettingsError.self) { _ = try CloudVisionSettings.load(from: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
        #expect(throws: CloudVisionSettingsError.self) { _ = try CloudVisionSettings.load(from: url) }
        #expect(throws: CloudVisionSettingsError.self) { try settings.save(to: url) }
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o755)
    }

    @Test func fullWindowRequiresSupportedVisionProvider() throws {
        var settings = CloudVisionSettings()
        try settings.setAPIKey("synthetic-qwen", for: .qwen)
        try settings.setAPIKey("synthetic-deepseek", for: .deepseek)
        try settings.enable()
        try settings.setFullWindowEnabled(true)
        #expect(settings.fullWindowEnabled)
        try settings.setProvider(.deepseek)
        #expect(!settings.fullWindowEnabled)
        #expect(throws: CloudVisionSettingsError.self) {
            try settings.setFullWindowEnabled(true)
        }
        try settings.setProvider(.qwen)
        #expect(!settings.fullWindowEnabled)
    }
}
