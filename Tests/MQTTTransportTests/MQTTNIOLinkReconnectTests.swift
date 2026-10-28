import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import MQTTTransport

/// B63: MQTTNIOLink's reconnects against `FakeMQTTBroker` on 127.0.0.1. The broker counts the CONNECTs the link
/// makes, so each test reads the reconnect behaviour as a broker would see it.
@Suite("MQTTNIOLink reconnects")
struct MQTTNIOLinkReconnectTests {
    @Test func aRefusedConnectIsRetriedOnce() async throws {
        // The refused socket closes at once, so the failed connect and the close both report; the retry is never answered.
        let broker = try FakeMQTTBroker { $0 == 1 ? .refuse(reason: 0x87, closeAfter: 0) : .hold }
        defer { broker.shutdown() }
        let started = ContinuousClock.now
        let link = try Self.startLink(port: broker.port)
        defer { link.stop() }
        try await Task.sleep(until: started + .milliseconds(2600), clock: .continuous)
        #expect(broker.connections == 2)
    }

    @Test func aLateCloseOfARefusedAttemptLeavesTheNextConnectionUp() async throws {
        // The refused socket only closes after 2 s, by when the retry has connected.
        let broker = try FakeMQTTBroker { $0 == 1 ? .refuse(reason: 0x87, closeAfter: 2) : .accept(closeAfter: nil) }
        defer { broker.shutdown() }
        let started = ContinuousClock.now
        let link = try Self.startLink(port: broker.port)
        defer { link.stop() }
        #expect(try await Self.eventually(within: 3) { link.isConnected })
        try await Task.sleep(until: started + .milliseconds(3600), clock: .continuous)
        #expect(broker.connections == 2)
        #expect(broker.openConnections == 1)
        #expect(link.isConnected)
    }

    @Test func aBrokerThatDropsEveryConnectionIsRetriedLessAndLessOften() async throws {
        let broker = try FakeMQTTBroker { _ in .accept(closeAfter: 0) }
        defer { broker.shutdown() }
        let started = ContinuousClock.now
        let link = try Self.startLink(port: broker.port)
        defer { link.stop() }
        try await Task.sleep(until: started + .milliseconds(4600), clock: .continuous)
        // Delays double from 1 s, each somewhere in its upper half: CONNECTs at 0, 0.5–1, 1.5–3 and 3.5–7 s.
        #expect((3...4).contains(broker.connections))
    }

    static func startLink(port: Int) throws -> MQTTNIOLink {
        let settings = MQTTSettings(host: "127.0.0.1", port: port, controllerID: "reconnect-test")
        let link = MQTTNIOLink(settings: settings, log: { _ in })
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: BindingFakeHandler()))
        link.start(binding: MQTTBinding(settings: settings, dispatcher: dispatcher, store: store, link: link))
        return link
    }

    static func eventually(within seconds: Int, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
