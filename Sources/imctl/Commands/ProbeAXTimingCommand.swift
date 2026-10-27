import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

struct ProbeAXTimingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax-timing",
        abstract: "Read the client both ways, one AX attribute at a time and batched, and compare timings, round trips and whether the parses agree. Read-only; prints numbers only, no text."
    )

    @OptionGroup var options: ProbeOptions
    @Option(name: .customLong("repeat"), help: "Rounds of each mode (1-20).") var rounds: Int = 3

    func validate() throws {
        guard (1...20).contains(rounds) else { throw ValidationError("--repeat must be between 1 and 20") }
    }

    func collect() throws -> AXTimingProbe.Result {
        if let path = options.fromFixture {
            let fake = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: path)))
            // A recording stands in for a client element that can batch.
            fake.batchesReads = true
            return try AXTimingProbe.run(rounds: rounds, base: fake, root: { AXElement(handle: fake.rootHandle, backend: $0) })
        }
        let live = LiveAXBackend()
        guard live.isProcessTrusted(prompt: false) else { throw IMCTLError.notTrusted }
        let bundle = options.bundle
        return try AXTimingProbe.run(rounds: rounds, base: live, root: { try AXApp.byBundleID(bundle, backend: $0) })
    }

    func run() throws {
        let result = try collect()
        print(options.json ? try ProbeSession.encode(result) : AXTimingProbe.render(result))
    }
}
