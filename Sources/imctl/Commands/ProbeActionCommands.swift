import AppKit
import ArgumentParser
import AXKit
import ControlCore
import CoreGraphics
import Foundation
import WeComAdapter

enum ProbePolicy {
    /// The compiled-in allowlist. Widening it is a wiki-recorded human decision.
    static func make(enabled: Set<ActionKind>) -> ActionPolicy {
        ActionPolicy(allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: enabled, phase: .phase0)
    }
}

struct SelectOutput: Codable {
    var before: ClientState
    var outcome: ActionOutcome
    var after: ClientState
}

struct ProbeSelectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select an allowlisted conversation via AXSelectedRows and verify the active title (G0-3)."
    )

    @OptionGroup var options: ProbeOptions
    @Option(name: .customLong("allow-select"), help: "Exact title of the conversation to select; must be allowlisted.")
    var allowSelect: String

    func collect() throws -> SelectOutput {
        let reader = try ProbeSession.reader(options)
        let fixture = options.fromFixture != nil
        let before = ClientState.sample(bundleID: options.bundle, fixture: fixture)
        let actions = WeComActions(policy: ProbePolicy.make(enabled: [.selectConversation]))
        let outcome = try actions.selectConversation(allowSelect, reader: reader)
        let after = ClientState.sample(bundleID: options.bundle, fixture: fixture)
        return SelectOutput(before: before, outcome: outcome, after: after)
    }

    func run() throws {
        let out = try collect()
        if options.json {
            print(try ProbeSession.encode(out))
        } else {
            print("before: \(out.before.summary)")
            print("select: \(out.outcome.kind) target=\(out.outcome.target ?? "-") verified=\(out.outcome.verified) \(out.outcome.details)")
            print("after:  \(out.after.summary)")
        }
    }
}

struct ButtonInfo: Codable, Equatable {
    var title: String?
    var description: String?
    var enabled: Bool?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct ComposeOutput: Codable {
    var before: ClientState
    var composed: ActionOutcome
    var newButtons: [ButtonInfo]
    var buttonsBefore: Int
    var buttonsAfter: Int
    var cleared: ActionOutcome?
    var after: ClientState
}

struct ProbeComposeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Set the composer text (never sends), report buttons that appear, optionally clear (G0-3)."
    )

    @OptionGroup var options: ProbeOptions
    @Option(name: .customLong("allow-compose"), help: "Text to place in the composer of the active (allowlisted) conversation.")
    var allowCompose: String
    @Flag(help: "Clear the composer afterwards and verify it is empty.") var clear = false
    @Flag(help: "Activate the client (NSRunningApplication.activate) before composing and restore the previous app afterwards; checks whether a send button only exists while the window is active.")
    var activate = false

    func collect() throws -> ComposeOutput {
        let reader = try ProbeSession.reader(options)
        let fixture = options.fromFixture != nil
        let before = ClientState.sample(bundleID: options.bundle, fixture: fixture)
        var enabled: Set<ActionKind> = [.composeText]
        if clear { enabled.insert(.clearComposer) }
        let actions = WeComActions(policy: ProbePolicy.make(enabled: enabled))

        let previous = NSWorkspace.shared.frontmostApplication
        if activate, !fixture, let app = AXApp.runningApplication(bundleID: options.bundle) {
            app.activate()
            Thread.sleep(forTimeInterval: 1.0)
        }
        defer {
            if activate, !fixture { previous?.activate() }
        }
        let buttonsBefore = buttons(in: reader.layout.window)
        let composed = try actions.composeText(allowCompose, reader: reader)
        if !fixture { Thread.sleep(forTimeInterval: 0.5) }
        let buttonsAfter = buttons(in: reader.layout.window)
        let newButtons = buttonsAfter.filter { !buttonsBefore.contains($0) }

        var cleared: ActionOutcome?
        if clear { cleared = try actions.clearComposer(reader: reader) }
        let after = ClientState.sample(bundleID: options.bundle, fixture: fixture)
        let redact = ProbeSession.redactor(options)
        return ComposeOutput(
            before: before, composed: composed,
            newButtons: newButtons.map { ButtonInfo(title: redact($0.title), description: redact($0.description), enabled: $0.enabled, x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
            buttonsBefore: buttonsBefore.count, buttonsAfter: buttonsAfter.count,
            cleared: cleared, after: after
        )
    }

    private func buttons(in window: AXElement) -> [ButtonInfo] {
        window.descendants().compactMap { el in
            guard (try? el.role()) == AXRole.button else { return nil }
            let f = (try? el.frame()) ?? .zero
            return ButtonInfo(title: try? el.title(), description: try? el.axDescription(), enabled: try? el.isEnabled(),
                              x: f.minX, y: f.minY, width: f.width, height: f.height)
        }
    }

    func run() throws {
        let out = try collect()
        if options.json {
            print(try ProbeSession.encode(out))
        } else {
            print("before:  \(out.before.summary)")
            print("compose: target=\(out.composed.target ?? "-") verified=\(out.composed.verified) \(out.composed.details)")
            print("buttons: \(out.buttonsBefore) -> \(out.buttonsAfter); new:")
            for b in out.newButtons {
                print("  title=\(b.title ?? "-") desc=\(b.description ?? "-") enabled=\(b.enabled.map(String.init) ?? "?") at (\(Int(b.x)),\(Int(b.y)) \(Int(b.width))x\(Int(b.height)))")
            }
            if let c = out.cleared { print("clear:   verified=\(c.verified)") }
            print("after:   \(out.after.summary)")
        }
    }
}
