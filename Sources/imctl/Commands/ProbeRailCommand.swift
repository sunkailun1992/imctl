import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

struct ProbeRailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rail",
        abstract: "Read the navigation rail's badge pairs and whether the 通讯录 count can be attributed — the reading the daemon's watcher uses. Read-only; prints counts and geometry, no text."
    )

    @OptionGroup var options: ProbeOptions

    func collect() throws -> RailBadges.Reading {
        RailBadges.read(window: try WeComWindowLocator.mainWindow(from: try ProbeSession.root(options)))
    }

    func run() throws {
        let reading = try collect()
        if options.json { print(try ProbeSession.encode(reading)); return }
        let contacts = reading.contacts.map(String.init) ?? "unknown"
        print("通讯录: \(contacts)\(reading.problem.map { " (\($0))" } ?? "") spacing: \(reading.spacing.map { String(format: "%.0f", $0) } ?? "-")")
        for slot in reading.slots {
            let offset = slot.badgeOffset.map { String(format: "%+.2f", $0) } ?? "-"
            print("  list \(slot.listIndex) rail \(slot.railIndex.map(String.init) ?? "-") count \(slot.count.map(String.init) ?? "?") offset \(offset) inRail \(slot.badgeInRail)")
        }
    }
}
