import Darwin
import Foundation

/// A loopback MQTT 5 broker just large enough for the reconnect tests: answers each CONNECT from `script`,
/// SUBSCRIBE with SUBACK, a QoS 1 PUBLISH with PUBACK and PINGREQ with PINGRESP, and counts connections.
final class FakeMQTTBroker: @unchecked Sendable {
    enum Answer {
        /// CONNACK success; with `closeAfter` the broker drops the connection that many seconds later.
        case accept(closeAfter: TimeInterval?)
        /// CONNACK with a failure reason code; the socket closes `closeAfter` seconds later.
        case refuse(reason: UInt8, closeAfter: TimeInterval)
        /// No CONNACK; the socket stays open.
        case hold
    }

    let port: Int
    private let queue = DispatchQueue(label: "com.sunkailun.imctl.tests.fake-mqtt-broker")
    private let script: (Int) -> Answer
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var accepted = 0

    private final class Client {
        let number: Int
        let source: DispatchSourceRead
        var pending: [UInt8] = []
        init(number: Int, source: DispatchSourceRead) { self.number = number; self.source = source }
    }

    /// `script` gets each connection's number, counting from 1.
    init(script: @escaping (Int) -> Answer) throws {
        self.script = script
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.lastError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard listening, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let error = Self.lastError()
            close(fd)
            throw error
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    /// Connections accepted so far.
    var connections: Int { queue.sync { accepted } }

    /// Connections still open on the broker's side.
    var openConnections: Int { queue.sync { clients.count } }

    func shutdown() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for (fd, client) in clients { drop(client, fd: fd) }
        }
    }

    private static func lastError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private func acceptPending(on listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            accepted += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let client = Client(number: accepted, source: source)
            clients[fd] = client
            source.setEventHandler { [weak self] in self?.receive(on: fd, from: client) }
            source.setCancelHandler { close(fd) }
            source.resume()
        }
    }

    private func receive(on fd: Int32, from client: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            if count < 0, errno == EAGAIN { return }
            drop(client, fd: fd)
            return
        }
        client.pending += chunk[..<count]
        while clients[fd] === client, let (first, body) = Self.takePacket(from: &client.pending) {
            answer(first, body, on: fd, from: client)
        }
    }

    private func answer(_ first: UInt8, _ body: [UInt8], on fd: Int32, from client: Client) {
        switch first >> 4 {
        case 1: // CONNECT
            switch script(client.number) {
            case .accept(let closeAfter):
                send([0x20, 0x03, 0x00, 0x00, 0x00], to: fd)
                if let closeAfter { drop(client, fd: fd, after: closeAfter) }
            case .refuse(let reason, let closeAfter):
                send([0x20, 0x03, 0x00, reason, 0x00], to: fd)
                drop(client, fd: fd, after: closeAfter)
            case .hold:
                break
            }
        case 8 where body.count >= 2: // SUBSCRIBE: grant QoS 1 to its one filter
            send([0x90, 0x04, body[0], body[1], 0x00, 0x01], to: fd)
        case 3 where (first >> 1) & 0x03 == 1 && body.count >= 2: // QoS 1 PUBLISH: the packet id follows the topic
            let id = 2 + (Int(body[0]) << 8 | Int(body[1]))
            if body.count >= id + 2 { send([0x40, 0x02, body[id], body[id + 1]], to: fd) }
        case 12: // PINGREQ
            send([0xD0, 0x00], to: fd)
        case 14: // DISCONNECT
            drop(client, fd: fd)
        default:
            break
        }
    }

    /// The first whole packet in `buffer` (first byte and body), removed from it; nil until all of it has arrived.
    static func takePacket(from buffer: inout [UInt8]) -> (UInt8, [UInt8])? {
        var length = 0, shift = 0, index = 1
        repeat {
            guard index < buffer.count, shift <= 21 else { return nil }
            length |= Int(buffer[index] & 0x7F) << shift
            shift += 7
            index += 1
        } while buffer[index - 1] & 0x80 != 0
        guard buffer.count >= index + length else { return nil }
        defer { buffer.removeFirst(index + length) }
        return (buffer[0], Array(buffer[index..<(index + length)]))
    }

    private func send(_ bytes: [UInt8], to fd: Int32) {
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func drop(_ client: Client, fd: Int32, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.drop(client, fd: fd) }
    }

    /// Closing the read source closes the socket; a later connection may reuse the descriptor, hence the identity check.
    private func drop(_ client: Client, fd: Int32) {
        guard clients[fd] === client else { return }
        clients[fd] = nil
        client.source.cancel()
    }
}
