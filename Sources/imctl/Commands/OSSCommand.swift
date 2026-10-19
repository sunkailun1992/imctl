import ArgumentParser
import ControlCore
import Foundation
import OSSClient

struct OSSCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oss",
        abstract: "Object store behind message.media and message.sendFile{ossKey}: write oss.json (0600, never committed), show it masked, run a 1 KB round trip.",
        subcommands: [OSSSetCommand.self, OSSStatusCommand.self, OSSTestCommand.self]
    )
}

struct OSSSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Write oss.json. An omitted --access-key-secret keeps the stored one; prefer --secret-stdin to keep it out of shell history.")
    @Option(help: "Endpoint, e.g. https://oss-cn-hangzhou.aliyuncs.com (region is derived from it).") var endpoint: String
    @Option(help: "Private bucket name.") var bucket: String
    @Option(name: .customLong("base-dir"), help: "Object key prefix, e.g. imctl.") var baseDir: String
    @Option(name: .customLong("access-key-id"), help: "RAM AccessKeyId (a sub-account limited to this bucket).") var accessKeyId: String
    @Option(name: .customLong("access-key-secret"), help: "AccessKeySecret; omit to keep the stored one.") var accessKeySecret: String?
    @Flag(name: .customLong("secret-stdin"), help: "Read the secret from stdin (first line).") var secretStdin = false
    @Option(name: .customLong("view-expire"), help: "Signed URL lifetime in seconds.") var viewExpire: Int = 1800
    @Option(name: .customLong("max-upload"), help: "Largest file message.media will upload, bytes.") var maxUpload: Int64 = 52_428_800
    @Option(help: "Settings file path.") var config: String = OSSSettings.defaultURL.path

    /// Test seam: `--secret-stdin` reads through here instead of calling `readLine()` directly, so tests can
    /// feed a fake line without touching the process's real stdin. Reset to the default after overriding it.
    static var readSecretLine: () -> String? = { readLine(strippingNewline: true) }

    func validate() throws {
        guard endpoint.hasPrefix("https://") else { throw ValidationError("--endpoint must start with https://") }
        // `run()` stores `--base-dir` trimmed of slashes, so "/" is as empty as "" is.
        guard !bucket.isEmpty, !baseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty, !accessKeyId.isEmpty else {
            throw ValidationError("--bucket, --base-dir and --access-key-id are required")
        }
    }

    func run() throws {
        let url = URL(fileURLWithPath: config)
        var secret = accessKeySecret ?? ""
        if secretStdin { secret = (Self.readSecretLine() ?? "").trimmingCharacters(in: .whitespaces) }
        if secret.isEmpty { secret = (try? OSSSettings.load(from: url))?.accessKeySecret ?? "" }
        guard !secret.isEmpty else { throw ValidationError("no secret given and none stored; pass --access-key-secret or --secret-stdin") }
        let settings = OSSSettings(endpoint: endpoint, bucket: bucket, baseDir: baseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")), accessKeyId: accessKeyId,
                                   accessKeySecret: secret, viewExpireSeconds: max(60, viewExpire), maxUploadBytes: max(1, maxUpload))
        guard !settings.region.isEmpty else { throw ValidationError("cannot derive the region from \(endpoint); expected a host like oss-cn-hangzhou.aliyuncs.com") }
        try settings.save(to: url)
        print("saved \(config) (0600): \(settings.summary)")
        print("restart the daemon (状态页 › 重启, or launchctl kickstart) so it picks up oss.json; then `imctl oss test`")
    }
}

struct OSSStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether oss.json exists and its masked summary (never the secret).")
    @Option(help: "Settings file path.") var config: String = OSSSettings.defaultURL.path
    @Flag var json = false

    func collect() throws -> [String: Any] {
        var out: [String: Any] = ["file": config, "present": FileManager.default.fileExists(atPath: config)]
        if out["present"] as? Bool == true {
            let s = try OSSSettings.load(from: URL(fileURLWithPath: config))
            out["summary"] = s.summary; out["region"] = s.region; out["viewExpireSeconds"] = s.viewExpireSeconds; out["maxUploadBytes"] = s.maxUploadBytes
        }
        return out
    }

    /// The exact text `--json` prints, factored out of `run()` so tests can assert it never carries a secret
    /// without capturing stdout.
    func jsonText() throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: try collect(), options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    func run() throws {
        if json { print(try jsonText()) }
        else { for (k, v) in try collect().sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") } }
    }
}

struct OSSTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Round trip a 1 KB probe object: PUT → HEAD → presigned GET → download → DELETE. Prints steps and HTTP codes only.")
    @Option(help: "Settings file path.") var config: String = OSSSettings.defaultURL.path

    func run() throws {
        let settings = try OSSSettings.load(from: URL(fileURLWithPath: config))
        try OSSRoundTrip.run(store: OSSObjectStore(settings: settings), keyPrefix: "_probe") { print($0) }
        print("ok: \(settings.summary)")
    }
}
