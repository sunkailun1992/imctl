import Darwin
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("UnixSocketServer permissions", .serialized)
struct UnixSocketServerTests {
    func server(at path: String) throws -> UnixSocketServer {
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let s = UnixSocketServer(dispatcher: dispatcher, path: path)
        s.log = { _ in }
        return s
    }

    /// `sockaddr_un.sun_path` is 104 bytes on macOS, so the per-test directory
    /// must be short — the usual temporaryDirectory path alone exceeds it.
    func tempPath() -> String {
        "/tmp/imctl-t-\(UUID().uuidString.prefix(8))/s.sock"
    }

    func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    @Test func socketAndDirectoryAreOwnerOnly() throws {
        let path = tempPath()
        let server = try server(at: path)
        try server.start()
        defer { server.stop(); cleanUp(path) }
        let socketMode = try #require((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue)
        #expect(socketMode & 0o077 == 0, "socket mode \(String(socketMode, radix: 8))")
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let dirMode = try #require((try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue)
        #expect(dirMode & 0o077 == 0, "directory mode \(String(dirMode, radix: 8))")
    }

    /// The umask can only be read by setting it and putting it back.
    static func currentUmask() -> mode_t {
        let mask = umask(0o022)
        umask(mask)
        return mask
    }

    /// The umask is process-wide: narrowing it across the bind gave a directory another thread created in that
    /// moment mode 0600, unusable (B53 merge runs: a test could not write into its own temporary directory, and
    /// a umask read here saw another server's 0o177). Binding leaves it alone; the owner-only directory and the
    /// chmod before listen keep the socket private (`socketAndDirectoryAreOwnerOnly`).
    @Test func bindingLeavesTheProcessUmaskAlone() throws {
        let before = Self.currentUmask()
        let path = tempPath()
        let server = try server(at: path)
        var atBind: mode_t?
        server.willBind = { atBind = Self.currentUmask() }
        try server.start()
        defer { server.stop(); cleanUp(path) }
        #expect(atBind == before)
        #expect(Self.currentUmask() == before)
    }

    @Test func worldReadableDirectoryIsRefused() throws {
        let dir = URL(fileURLWithPath: "/tmp/imctl-o-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        let server = try server(at: path)
        #expect(throws: UnixSocketServer.SocketError.self) { try server.start() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func overlongPathIsRefusedBeforeAnySyscall() throws {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/s.sock"
        #expect(throws: UnixSocketServer.SocketError.pathTooLong(path, length: path.utf8.count)) {
            try server(at: path).start()
        }
    }

    @Test func serverAnswersARequestOverTheSocket() throws {
        let path = tempPath()
        let server = try server(at: path)
        try server.start()
        defer { server.stop(); cleanUp(path) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"conversation.list"}"# + "\n"
        _ = Array(request.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        #expect(n > 0)
        let response = String(decoding: chunk[0..<max(n, 0)], as: UTF8.self)
        #expect(response.contains("\"succeeded\""))
    }

    @Test func stopRemovesTheSocket() throws {
        let path = tempPath()
        let server = try server(at: path)
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        cleanUp(path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
