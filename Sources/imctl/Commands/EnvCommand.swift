import ArgumentParser
import AXKit
import WeComAdapter

struct EnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Report host state: TCC, clamshell, power, lock, displays, IM client, signing. Never prompts."
    )

    @Option(help: "Bundle identifier of the IM client to look for.") var bundle: String = WeComClient.bundleID
    @Flag var json = false

    func run() throws {
        let env = HostProbe.snapshot(bundleID: bundle, backend: LiveAXBackend())
        print(json ? try env.jsonString() : env.render())
    }
}
