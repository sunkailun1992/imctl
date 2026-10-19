import ControlCore
import Darwin
import Foundation

/// Blocking newline-delimited JSON-RPC client for `UnixSocketServer` (the
/// console, `imctl call`, tests). One connection per call: the daemon's
/// socket is local and cheap, and a fresh connection cannot mix up replies.
public final class UnixSocketClient {
    public let path: String
    public var timeout: TimeInterval

    /// The server's JSON-RPC `error` object (`data.code` carries the wire error code for -32000).
    public struct RPCError: Error, Equatable, CustomStringConvertible {
        public var code: Int
        public var message: String
        public var data: JSONValue?
        public init(code: Int, message: String, data: JSONValue?) { self.code = code; self.message = message; self.data = data }
        public var description: String {
            let extra = data.flatMap { try? $0.serialized() }.map { " \($0)" } ?? ""
            return "JSON-RPC error \(code): \(message)\(extra)"
        }
    }

    public enum TransportError: Error, Equatable, CustomStringConvertible {
        case connect(String)
        case timeout
        case closed
        case malformed(String)

        public var description: String {
            switch self {
            case .connect(let why): return "cannot connect: \(why)"
            case .timeout: return "no response before the timeout"
            case .closed: return "server closed the connection without answering"
            case .malformed(let line): return "malformed response: \(line.prefix(200))"
            }
        }
    }

    public init(path: String, timeout: TimeInterval = 30) {
        self.path = path
        self.timeout = timeout
    }

    public func call(_ method: String, params: [String: JSONValue] = [:]) throws -> JSONValue {
        let id = UUID().uuidString
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
        let line = try request.serialized() + "\n"
        let fd = try connect()
        defer { close(fd) }
        try writeAll(fd, Array(line.utf8))
        let response = try readLine(fd)
        guard let object = (try? JSONValue.parse(response))?.objectValue else { throw TransportError.malformed(response) }
        if let error = object["error"]?.objectValue {
            throw RPCError(code: Int(error["code"]?.numberValue ?? -1), message: error["message"]?.stringValue ?? "", data: error["data"])
        }
        guard let result = object["result"] else { throw TransportError.malformed(response) }
        return result
    }

    // MARK: Socket plumbing

    private func connect() throws -> Int32 {
        guard path.utf8.count <= UnixSocketServer.maxPathLength else {
            throw TransportError.connect("path longer than \(UnixSocketServer.maxPathLength) bytes")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.connect(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { src in raw.copyMemory(from: src) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw TransportError.connect("\(path): \(why)")
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw TransportError.timeout }
            guard written > 0 else { throw TransportError.closed }
            offset += written
        }
    }

    private func readLine(_ fd: Int32) throws -> String {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw (errno == EAGAIN || errno == EWOULDBLOCK) ? TransportError.timeout : TransportError.closed }
            if n == 0 { throw TransportError.closed }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return String(decoding: buffer[..<newline], as: UTF8.self)
            }
        }
    }
}

extension ReadinessRestartAnswer {
    /// Review I3b: no answer is not "nothing running". Only a refused connection (nothing listens) and an older
    /// daemon (method not found) let a restart go ahead without a count.
    public init(error: Error) {
        if let rpc = error as? UnixSocketClient.RPCError { self = rpc.code == -32601 ? .oldDaemon : .noAnswer; return }
        if let transport = error as? UnixSocketClient.TransportError, case .connect = transport { self = .notRunning; return }
        self = .noAnswer
    }

    /// `call` asks `controller.readiness{online:false}` and returns its result.
    public static func asking(_ call: () throws -> JSONValue) -> ReadinessRestartAnswer {
        do {
            let text = try call().serialized()
            guard let report = try? JSONDecoder().decode(ReadinessReport.self, from: Data(text.utf8)) else { return .noAnswer }
            return .report(runningCommands: report.runningCommands)
        } catch {
            return ReadinessRestartAnswer(error: error)
        }
    }
}
