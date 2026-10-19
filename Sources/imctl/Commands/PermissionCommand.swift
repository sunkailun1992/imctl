import AppKit
import ArgumentParser
import AXKit

struct PermissionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission",
        abstract: "Check whether this process is trusted for Accessibility (exit 0 trusted, 2 not)."
    )

    @Flag(help: "Show the system prompt when not trusted.") var prompt = false
    @Flag(name: .customLong("open-settings"), help: "Open System Settings › Privacy & Security › Accessibility.") var openSettings = false
    @Flag var json = false

    func run() throws {
        let trusted = LiveAXBackend().isProcessTrusted(prompt: prompt)
        if openSettings, let url = AXPermission.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
        if json {
            print(#"{"trusted":\#(trusted)}"#)
        } else if trusted {
            print("accessibility: trusted")
        } else {
            print("accessibility: NOT trusted (use --prompt or --open-settings, then approve this binary)")
        }
        if !trusted { throw ExitCode(2) }
    }
}
