import ArgumentParser
import ControlCore

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print version and bundle identifier.")

    @Flag var json = false

    func run() throws {
        if json {
            print(#"{"version":"\#(IMCTLVersion.string)","bundleIdentifier":"\#(IMCTLVersion.bundleIdentifier)"}"#)
        } else {
            print("imctl \(IMCTLVersion.string) (\(IMCTLVersion.bundleIdentifier))")
        }
    }
}
