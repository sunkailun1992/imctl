import ControlCore
import Foundation

/// Where the console finds the daemon. Environment overrides exist so a
/// development build can talk to a temporary daemon instead of the LaunchAgent.
enum ConsolePaths {
    static var socket: String { ProcessInfo.processInfo.environment["IMCTL_SOCKET"] ?? IMCTLPaths.socket.path }
    static var stateFile: URL {
        ProcessInfo.processInfo.environment["IMCTL_STATE"].map { URL(fileURLWithPath: $0) } ?? IMCTLPaths.stateFile
    }
    static var logDirectory: URL { IMCTLPaths.logDirectory }
}
