import ControlCore
import Foundation

/// Local opt-in for sending WeCom pixels to an official vision API. Full-window
/// task planning has a separate grant, absent in older B16 configuration files.
/// Each provider has its own key; neither this value nor its JSON representation may be logged.
public struct CloudVisionSettings: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public private(set) var cloudEnabled: Bool
    public private(set) var provider: CloudVisionProvider
    private var models: [String: String]
    private var apiKeys: [String: String]
    private var fullWindowApproval: Bool?

    public static let fileName = "cloud-vision.json"
    public static var defaultDirectory: URL { IMCTLPaths.dataDirectory.appendingPathComponent("vision", isDirectory: true) }
    public static var defaultURL: URL { defaultDirectory.appendingPathComponent(fileName) }

    public init() {
        cloudEnabled = false
        provider = .qwen
        models = [:]
        apiKeys = [:]
        fullWindowApproval = nil
    }

    public var model: String { models[provider.rawValue] ?? Self.defaultModel(for: provider) }
    public var keyPresent: Bool { keyPresent(for: provider) }
    public var fullWindowEnabled: Bool {
        cloudEnabled && fullWindowApproval == true && (provider == .qwen || provider == .gemini)
    }

    public static func allowedModels(for provider: CloudVisionProvider) -> [String] {
        switch provider {
        case .qwen: ["qwen3.7-plus", "qwen3.8-flash", "qwen3.8-max", "qwen3-vl-plus", "qwen3-vl-flash"]
        case .gemini: ["gemini-3.8-flash", "gemini-3.7-flash"]
        case .deepseek: ["deepseek-flash"]
        }
    }

    public static func defaultModel(for provider: CloudVisionProvider) -> String {
        allowedModels(for: provider)[0]
    }

    /// Only the local inference client receives this value; status and descriptions report presence only.
    public func apiKey(for provider: CloudVisionProvider) -> String? { apiKeys[provider.rawValue] }
    public func keyPresent(for provider: CloudVisionProvider) -> Bool { apiKeys[provider.rawValue] != nil }

    public mutating func setProvider(_ provider: CloudVisionProvider, model: String? = nil) throws {
        let chosen = model ?? models[provider.rawValue] ?? Self.defaultModel(for: provider)
        guard Self.allowedModels(for: provider).contains(chosen) else {
            throw CloudVisionSettingsError.invalidModel
        }
        self.provider = provider
        models[provider.rawValue] = chosen
        if provider == .deepseek { fullWindowApproval = false }
    }

    public mutating func setAPIKey(_ value: String, for provider: CloudVisionProvider) throws {
        guard !value.isEmpty, value.count <= 4096,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CloudVisionSettingsError.invalidAPIKey
        }
        apiKeys[provider.rawValue] = value
    }

    public mutating func removeAPIKey(for provider: CloudVisionProvider) {
        apiKeys.removeValue(forKey: provider.rawValue)
        if self.provider == provider { cloudEnabled = false; fullWindowApproval = false }
    }

    public mutating func enable() throws {
        guard keyPresent else { throw CloudVisionSettingsError.keyMissing }
        cloudEnabled = true
    }

    public mutating func disable() { cloudEnabled = false; fullWindowApproval = false }

    /// Requires a separate local decision because the B16 switch authorized only
    /// small button crops. Older files decode this optional field as absent.
    public mutating func setFullWindowEnabled(_ enabled: Bool) throws {
        if enabled {
            guard cloudEnabled && keyPresent else { throw CloudVisionSettingsError.keyMissing }
            guard provider == .qwen || provider == .gemini else {
                throw CloudVisionSettingsError.unsupportedFullWindowProvider
            }
        }
        fullWindowApproval = enabled
    }

    /// Missing is a first-run state; malformed or overly exposed files fail closed.
    public static func loadOrDefault(from url: URL = defaultURL) throws -> CloudVisionSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return CloudVisionSettings() }
        return try load(from: url)
    }

    public static func load(from url: URL = defaultURL) throws -> CloudVisionSettings {
        try checkPrivateFile(at: url)
        let settings: CloudVisionSettings
        do { settings = try JSONDecoder().decode(CloudVisionSettings.self, from: Data(contentsOf: url)) }
        catch { throw CloudVisionSettingsError.malformedSettings }
        try settings.validate()
        return settings
    }

    public func save(to url: URL = defaultURL) throws {
        try validate()
        let parent = url.deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: parent.path) {
            guard (try? fm.destinationOfSymbolicLink(atPath: parent.path)) == nil else {
                throw CloudVisionSettingsError.insecurePermissions
            }
            let attributes = try fm.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                throw CloudVisionSettingsError.insecurePermissions
            }
        } else {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }
        if fm.fileExists(atPath: url.path) { try Self.checkPrivateFile(at: url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func validate() throws {
        for (name, model) in models {
            guard let provider = CloudVisionProvider(rawValue: name), Self.allowedModels(for: provider).contains(model) else {
                throw CloudVisionSettingsError.invalidModel
            }
        }
        for (name, value) in apiKeys {
            guard let provider = CloudVisionProvider(rawValue: name) else { throw CloudVisionSettingsError.invalidProvider }
            var copy = CloudVisionSettings()
            try copy.setAPIKey(value, for: provider)
        }
        guard Self.allowedModels(for: provider).contains(model) else { throw CloudVisionSettingsError.invalidModel }
        if cloudEnabled && !keyPresent { throw CloudVisionSettingsError.keyMissing }
    }

    private static func checkPrivateFile(at url: URL) throws {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: url.deletingLastPathComponent().path)) == nil,
              (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw CloudVisionSettingsError.insecurePermissions
        }
        let parent = try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let file = try fm.attributesOfItem(atPath: url.path)
        guard parent[.type] as? FileAttributeType == .typeDirectory,
              file[.type] as? FileAttributeType == .typeRegular,
              (parent[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (file[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw CloudVisionSettingsError.insecurePermissions
        }
    }

    public var description: String {
        "CloudVisionSettings(enabled=\(cloudEnabled), fullWindowEnabled=\(fullWindowEnabled), provider=\(provider.rawValue), model=\(model), keyPresent=\(keyPresent))"
    }
    public var debugDescription: String { description }
}

/// Error descriptions name only the rejected field, never a supplied value.
public enum CloudVisionSettingsError: Error, LocalizedError {
    case invalidProvider, invalidModel, invalidAPIKey, keyMissing, unsupportedFullWindowProvider, insecurePermissions, malformedSettings

    public var errorDescription: String? {
        switch self {
        case .invalidProvider: "unsupported cloud vision provider"
        case .invalidModel: "unsupported cloud vision model for provider"
        case .invalidAPIKey: "invalid cloud vision API key"
        case .keyMissing: "cloud vision API key is not configured for the selected provider"
        case .unsupportedFullWindowProvider: "selected provider does not support full-window visual planning"
        case .insecurePermissions: "cloud vision settings require a 0700 directory and 0600 regular file"
        case .malformedSettings: "cloud vision settings file is invalid"
        }
    }
}
