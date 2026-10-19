import ArgumentParser
import ControlCore
import Foundation
import WeComAdapter

struct ProbeMenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu",
        abstract: "Open the composer's context menu, list its items (looking for 发送), close it. Never activates an item."
    )

    @OptionGroup var options: ProbeOptions
    @Flag(name: .customLong("allow-menu"), help: "Required: performs AXShowMenu on the composer of the allowlisted active conversation.")
    var allowMenu = false

    func validate() throws {
        guard allowMenu else { throw ValidationError("pass --allow-menu to perform AXShowMenu") }
    }

    func collect() throws -> ComposerMenuReport {
        let reader = try ProbeSession.reader(options)
        let actions = WeComActions(policy: ActionPolicy(
            allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: [.showComposerMenu], phase: .phase0
        ))
        return try actions.inspectComposerMenu(reader: reader)
    }

    func run() throws {
        let report = try collect()
        if options.json { print(try ProbeSession.encode(report)); return }
        print("menu_found: \(report.menuFound) closed: \(report.closed) via \(report.closeMethod ?? "-")")
        for item in report.items { print("  - \(item)") }
    }
}
