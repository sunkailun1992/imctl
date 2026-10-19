import Darwin
import Foundation

/// Newline-delimited JSON-RPC over a Unix domain socket (local Java, agents).
///
/// Implemented on POSIX sockets rather than Network.framework so the bind
/// itself is under our control: this endpoint executes commands (including
/// `message.send`), so the socket must never be reachable by other users —
/// not even for the moment between `bind` and its `chmod`. The parent
/// directory must already be owner-only, the socket is chmod 0600 right after
/// the bind, and its mode is verified before `listen`, so nothing is accepted
/// before it is private. The process umask is left alone (B53): it is
/// process-wide, and narrowing it across the bind gave a directory another
/// thread created in that moment mode 0600, which is unusable.
public final class UnixSocketServer {
    public let dispatcher: RPCDispatcher
    public let path: String
    public var log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// Accept and the `connections` table. Each connection reads and answers on its own serial queue (B52
    /// review): one slow request (a long command) no longer holds every other client, while commands are
    /// still run one at a time by the executor.
    /// Internal (not private) for the test that calls `stop()` on it.
    let queue = DispatchQueue(label: "com.sunkailun.imctl.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: DispatchSourceRead] = [:]
    /// Marks `queue`, so `stop()` from a deinit that runs on it does not sync onto itself.
    private let queueKey = DispatchSpecificKey<Void>()

    /// macOS `sockaddr_un.sun_path` is 104 bytes including the terminator.
    public static let maxPathLength = 103

    /// Tests: runs on the starting thread just before bind(2).
    var willBind: (() -> Void)?

    public init(dispatcher: RPCDispatcher, path: String) {
        self.dispatcher = dispatcher
        self.path = path
        queue.setSpecific(key: queueKey, value: ())
    }

    public enum SocketError: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String, length: Int)
        case directoryNotPrivate(String, mode: Int)
        case socketNotPrivate(String, mode: Int)
        case syscall(String, errno: Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let p, let n):
                return "socket path is \(n) bytes, max \(UnixSocketServer.maxPathLength): \(p)"
            case .directoryNotPrivate(let p, let m):
                return "socket directory \(p) is mode \(String(m, radix: 8)), need owner-only (0700)"
            case .socketNotPrivate(let p, let m):
                return "socket \(p) is mode \(String(m, radix: 8)), need 0600"
            case .syscall(let call, let e):
                return "\(call) failed: \(String(cString: strerror(e))) (errno \(e))"
            }
        }
    }

    // MARK: Lifecycle

    public func start() throws {
        let bytes = path.utf8.count
        guard bytes <= Self.maxPathLength else { throw SocketError.pathTooLong(path, length: bytes) }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dirMode = try mode(of: directory.path)
        guard dirMode & 0o077 == 0 else { throw SocketError.directoryNotPrivate(directory.path, mode: dirMode) }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { src in
                raw.copyMemory(from: src)
            }
        }

        willBind?()
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno
        guard bindResult == 0 else {
            close(fd)
            throw SocketError.syscall("bind", errno: bindErrno)
        }
        // Until this chmod the socket has the umask's default mode, but its
        // directory is owner-only and nothing listens yet.
        guard chmod(path, 0o600) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketError.syscall("chmod", errno: e)
        }
        let socketMode = try mode(of: path)
        guard socketMode & 0o077 == 0 else {
            close(fd)
            unlink(path)
            throw SocketError.socketNotPrivate(path, mode: socketMode)
        }
        guard listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketError.syscall("listen", errno: e)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    deinit { stop() }

    public func stop() {
        let closeAll = {
            for (fd, source) in self.connections {
                source.cancel()
                _ = fd
            }
            self.connections.removeAll()
        }
        // The last reference can drop inside a block on `queue` (then deinit runs there): never sync onto it.
        if DispatchQueue.getSpecific(key: queueKey) != nil { closeAll() } else { queue.sync(execute: closeAll) }
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(path)
    }

    // MARK: Connections

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var buffer = Data()
        let connectionQueue = DispatchQueue(label: "com.sunkailun.imctl.socket.connection")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: connectionQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                // Stop here, on this connection's queue, so EOF fires no more events; the fd closes in the cancel
                // handler. Its number can then go to the next connection, so the table entry is removed only while
                // it is still this connection.
                source.cancel()
                self.queue.async { [weak self] in
                    guard let self, self.connections[fd] === source else { return }
                    self.connections[fd] = nil
                }
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let response = self.dispatcher.handle(line: line) {
                    self.write(response + "\n", to: fd)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        connections[fd] = source
        source.resume()
    }

    private func write(_ text: String, to fd: Int32) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
    }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    }
}
