import Foundation

/// B53: facts only the reader's own process knows (its build, whether `imctl` is on the terminal's PATH).
public enum ReadinessClient {
    /// CFBundleVersion of the app at `appURL`, read from disk each time (`Bundle` caches its Info.plist);
    /// nil outside an `.app` (development builds).
    public static func bundleBuild(at appURL: URL?) -> String? {
        guard let appURL, appURL.pathExtension == "app",
              let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    public static let linkCandidates = ["/usr/local/bin/imctl", "/opt/homebrew/bin/imctl"]

    /// The copyable command that puts `imctl` on PATH (the person runs it; it needs sudo). A new Mac may have no
    /// /usr/local/bin — the pkg creates it only for a system install — so the command creates it first.
    public static func linkCommand(cliPath: String) -> String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(cliPath)\" /usr/local/bin/imctl"
    }

    /// A standard PATH directory has an `imctl` that resolves to this bundle's CLI.
    public static func cliLinked(cliPath: String, candidates: [String] = linkCandidates,
                                 resolve: (String) -> String? = { path in
                                     FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : nil
                                 }) -> Bool {
        let target = URL(fileURLWithPath: cliPath).resolvingSymlinksInPath().path
        return candidates.contains { resolve($0) == target }
    }

    /// Numeric build comparison; false when either is not a number.
    public static func isOlder(_ build: String, than other: String) -> Bool {
        guard let a = Int(build), let b = Int(other) else { return false }
        return a < b
    }
}
