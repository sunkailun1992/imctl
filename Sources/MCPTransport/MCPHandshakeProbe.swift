import ControlCore
import Foundation

/// Starts `<cli> mcp serve` and runs the MCP handshake (B52 readiness). Only `initialize` and `tools/list` are
/// sent: the proxy answers both itself, so the probe never calls back into the daemon socket that is serving
/// the readiness request. Passes when the server names itself `imctl` and lists `controller.readiness`.
public enum MCPHandshakeProbe {
    static let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"imctl-readiness","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
    ]

    public static func run(executable: URL, timeout: TimeInterval = 10) -> ReadinessProbeResult {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp", "serve"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failure("launch", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
        try? writeRequests(to: input.fileHandleForWriting)
        try? input.fileHandleForWriting.close()
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failure("timeout", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
        // Output reached EOF, so the child is exiting; never wait on it unbounded.
        let exitDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        let latency = ReadinessProbeResult.elapsedMs(since: started)
        return verify(String(decoding: box.data, as: UTF8.self)) ? .success(latencyMs: latency) : .failure("protocol", latencyMs: latency)
    }

    /// A child that exits before reading would otherwise deliver SIGPIPE to this process (the daemon).
    /// With F_SETNOSIGPIPE the write fails with EPIPE, and the throwing API reports it as an error.
    static func writeRequests(to handle: FileHandle) throws {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        try handle.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
    }

    /// The two answers in order: `initialize` names the server `imctl`; `tools/list` contains `controller.readiness`.
    static func verify(_ output: String) -> Bool {
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count >= 2,
              let hello = try? JSONValue.parse(lines[0]),
              hello.objectValue?["result"]?.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue == AgentPaths.serverName,
              let list = try? JSONValue.parse(lines[1]),
              let tools = list.objectValue?["result"]?.objectValue?["tools"]?.arrayValue else { return false }
        return tools.contains { $0.objectValue?["name"]?.stringValue == RPCDispatcher.readinessMethod }
    }
}
