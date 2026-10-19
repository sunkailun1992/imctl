import ControlCore
import Foundation

enum DaemonPaths {
    static var root: URL { IMCTLPaths.dataDirectory }
    static var db: URL { IMCTLPaths.database }
    static var state: URL { IMCTLPaths.stateFile }
    static var checkpoints: URL { root.appendingPathComponent("checkpoints", isDirectory: true) }
}

struct DaemonLog {
    private let iso = ISO8601DateFormatter()
    func info(_ message: String) {
        FileHandle.standardError.write(Data("\(iso.string(from: Date())) imctld \(message)\n".utf8))
    }
}
