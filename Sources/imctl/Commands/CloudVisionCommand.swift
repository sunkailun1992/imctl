import ArgumentParser
import Foundation
import WeComAdapter

struct CloudVisionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vision",
        abstract: "Manage opt-in cloud vision for explicit WeCom control actions. Keys stay in a local 0600 file.",
        subcommands: [CloudVisionSetCommand.self, CloudVisionStatusCommand.self, CloudVisionFullWindowCommand.self,
                      CloudVisionDisableCommand.self, CloudVisionDeleteCommand.self]
    )
}

struct CloudVisionSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Select a provider/model and enable cloud vision. Set or replace its key using --secret-stdin."
    )

    @Option(help: "qwen, gemini or deepseek; omitted keeps the current provider (qwen on first use).") var provider: String?
    @Option(help: "Provider-specific allowlisted vision model; omitted keeps the current selection.") var model: String?
    @Flag(name: .customLong("secret-stdin"), help: "Read this provider's API key from stdin (first line). Never put it in an argument.") var secretStdin = false
    @Option(help: "Settings file path.") var config: String = CloudVisionSettings.defaultURL.path

    /// Test seam for stdin; never print the returned value or include it in thrown errors.
    static var readSecretLine: () -> String? = { readLine(strippingNewline: true) }

    func run() throws {
        let url = URL(fileURLWithPath: config)
        var settings = try CloudVisionSettings.loadOrDefault(from: url)
        let chosen = try Self.parseProvider(provider) ?? settings.provider
        try settings.setProvider(chosen, model: model)
        if secretStdin {
            guard let secret = Self.readSecretLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
                throw ValidationError("--secret-stdin supplied no API key")
            }
            try settings.setAPIKey(secret, for: chosen)
        }
        try settings.enable()
        try settings.save(to: url)
        print("cloud vision enabled: provider=\(settings.provider.rawValue) model=\(settings.model) keyPresent=\(settings.keyPresent); restart the daemon if it was started while disabled")
    }

    static func parseProvider(_ value: String?) throws -> CloudVisionProvider? {
        guard let value else { return nil }
        guard let parsed = CloudVisionProvider(rawValue: value.lowercased()) else {
            throw ValidationError("--provider must be qwen, gemini or deepseek")
        }
        return parsed
    }
}

struct CloudVisionStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show cloud vision state and key presence only.")
    @Option(help: "Settings file path.") var config: String = CloudVisionSettings.defaultURL.path
    @Flag var json = false

    func collect() throws -> [String: Any] {
        let present = FileManager.default.fileExists(atPath: config)
        let settings = try CloudVisionSettings.loadOrDefault(from: URL(fileURLWithPath: config))
        return [
            "present": present,
            "cloudEnabled": settings.cloudEnabled,
            "fullWindowEnabled": settings.fullWindowEnabled,
            "provider": settings.provider.rawValue,
            "model": settings.model,
            "keyPresent": settings.keyPresent,
            "keysPresent": Dictionary(uniqueKeysWithValues: CloudVisionProvider.allCases.map {
                ($0.rawValue, settings.keyPresent(for: $0))
            }),
        ]
    }

    func jsonText() throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: collect(), options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    func run() throws {
        if json { print(try jsonText()) }
        else {
            let state = try collect()
            print("cloud vision: \((state["cloudEnabled"] as? Bool) == true ? "enabled" : "disabled")")
            print("full WeCom window upload: \((state["fullWindowEnabled"] as? Bool) == true ? "enabled" : "disabled")")
            print("provider: \(state["provider"] ?? "qwen") model: \(state["model"] ?? "-") keyPresent: \(state["keyPresent"] ?? false)")
            if let keys = state["keysPresent"] as? [String: Bool] {
                for provider in CloudVisionProvider.allCases { print("\(provider.rawValue) keyPresent: \(keys[provider.rawValue] ?? false)") }
            }
        }
    }
}

struct CloudVisionFullWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "full-window",
        abstract: "Separately allow or stop full WeCom-window uploads for explicit desktop commands."
    )
    @Flag(help: "Allow full-window frames to the selected cloud provider for explicit commands.") var enable = false
    @Flag(help: "Stop full-window uploads while retaining the B16 small-crop setting.") var disable = false
    @Option(help: "Settings file path.") var config: String = CloudVisionSettings.defaultURL.path

    func run() throws {
        guard enable != disable else { throw ValidationError("choose exactly one of --enable or --disable") }
        let url = URL(fileURLWithPath: config)
        var settings = try CloudVisionSettings.load(from: url)
        try settings.setFullWindowEnabled(enable)
        try settings.save(to: url)
        print("full WeCom window upload \(enable ? "enabled" : "disabled") for explicit desktop commands")
    }
}

struct CloudVisionDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop cloud uploads; retain provider keys locally.")
    @Option(help: "Settings file path.") var config: String = CloudVisionSettings.defaultURL.path

    func run() throws {
        let url = URL(fileURLWithPath: config)
        var settings = try CloudVisionSettings.load(from: url)
        settings.disable()
        try settings.save(to: url)
        print("cloud vision disabled")
    }
}

struct CloudVisionDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one provider key with --provider, or delete the entire cloud vision settings file."
    )
    @Option(help: "Provider key to delete; omitted removes all cloud vision settings and keys.") var provider: String?
    @Option(help: "Settings file path.") var config: String = CloudVisionSettings.defaultURL.path

    func run() throws {
        let url = URL(fileURLWithPath: config)
        guard FileManager.default.fileExists(atPath: url.path) else { print("cloud vision settings absent"); return }
        if let provider = try CloudVisionSetCommand.parseProvider(provider) {
            var settings = try CloudVisionSettings.load(from: url)
            settings.removeAPIKey(for: provider)
            try settings.save(to: url)
            print("cloud vision \(provider.rawValue) key deleted")
        } else {
            _ = try CloudVisionSettings.load(from: url)
            try FileManager.default.removeItem(at: url)
            print("cloud vision settings and keys deleted")
        }
    }
}
