import ArgumentParser
import ControlCore
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show imctld state file and command/event counts.")

    @Option(help: "State file written by imctld.") var state: String = IMCTLPaths.stateFile.path
    @Option(help: "SQLite path used by imctld.") var db: String = IMCTLPaths.database.path
    @Flag var json = false

    func run() throws {
        var out: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: state)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            out["daemon"] = obj
            if let pid = obj["pid"] as? Int { out["daemonAlive"] = kill(pid_t(pid), 0) == 0 }
        } else {
            out["daemon"] = "no state file at \(state)"
        }
        if FileManager.default.fileExists(atPath: db) {
            let store = try ControlStore(path: db)
            out["commands"] = try store.commandCounts()
            out["lastEventId"] = try store.lastEventId()
            out["recentCommands"] = try store.recentCommands(limit: 5).map { ["id": $0.id, "method": $0.method, "state": $0.state.rawValue, "error": $0.errorCode ?? ""] }
        }
        if json {
            print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else {
            for (k, v) in out.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }
        }
    }
}
