import Foundation
import MCPTransport
import MQTTTransport

/// Owns everything that must live as long as the process: the transports, the
/// watcher, and the signal sources. Also guarantees the socket file and state
/// file are cleaned up on SIGTERM/SIGINT (launchd stops agents with SIGTERM).
final class DaemonRuntime {
    static var shared: DaemonRuntime?

    let log: DaemonLog
    var socketServer: UnixSocketServer?
    var mqttLink: MQTTNIOLink?
    var mqttBinding: MQTTBinding?
    var stdioServer: StdioServer?
    var watcher: DaemonWatcher?
    var statePath: URL?
    private var signalSources: [DispatchSourceSignal] = []

    init(log: DaemonLog) { self.log = log }

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.log.info("received signal \(sig); shutting down")
                self?.shutdown(exitCode: 0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func shutdown(exitCode: Int32) -> Never {
        mqttLink?.stop()
        socketServer?.stop()
        watcher?.stop()
        if let statePath { try? FileManager.default.removeItem(at: statePath) }
        log.info("imctld stopped")
        exit(exitCode)
    }
}
