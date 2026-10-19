import ControlCore
import Foundation
import MQTTNIO
import NIOCore
import NIOFoundationCompat

/// Live MQTT 5 client (MQTT-NIO). Persistent session so commands published
/// while we are offline are delivered on reconnect (QoS 1; the executor's
/// idempotency key absorbs redelivery). Will = retained `state` offline.
public final class MQTTNIOLink: MQTTLink {
    public let settings: MQTTSettings
    public var log: (String) -> Void
    /// Broker keeps the session (and queued QoS 1 commands) this long while we are away.
    public var sessionExpirySeconds: UInt32 = 86400

    private let client: MQTTClient
    private var binding: MQTTBinding?
    private let commandQueue = DispatchQueue(label: "com.sunkailun.imctl.mqtt.commands")
    private let pumpQueue = DispatchQueue(label: "com.sunkailun.imctl.mqtt.pump")
    private var pumpTimer: DispatchSourceTimer?
    private var reconnectDelay: TimeInterval = 1
    private var stopped = false
    private let stateLock = NSLock()
    private var connected = false

    public init(settings: MQTTSettings, log: @escaping (String) -> Void) {
        self.settings = settings
        self.log = log
        let configuration = MQTTClient.Configuration(
            version: .v5_0,
            keepAliveInterval: .seconds(Int64(settings.keepAliveSeconds)),
            userName: settings.username,
            password: settings.password,
            useSSL: settings.useTLS
        )
        client = MQTTClient(host: settings.host, port: settings.port, identifier: settings.clientID,
                            eventLoopGroupProvider: .createNew, configuration: configuration)
    }

    public var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connected
    }

    // MARK: Lifecycle

    public func start(binding: MQTTBinding) {
        self.binding = binding
        client.addPublishListener(named: "imctl.inbound") { [weak self] result in
            switch result {
            case .success(let info): self?.inbound(info)
            case .failure(let error): self?.log("mqtt: inbound error \(error)")
            }
        }
        client.addCloseListener(named: "imctl.close") { [weak self] _ in
            guard let self else { return }
            self.setConnected(false)
            self.log("mqtt: connection closed")
            self.scheduleReconnect()
        }
        connect()
    }

    public func stop() {
        stopped = true
        pumpTimer?.cancel()
        pumpTimer = nil
        if isConnected, let binding {
            _ = try? client.v5.publish(to: settings.stateTopic, payload: ByteBuffer(data: binding.statePayload(online: false)),
                                       qos: .atLeastOnce, retain: true).wait()
        }
        _ = try? client.v5.disconnect().wait()
        try? client.syncShutdownGracefully()
    }

    private func connect() {
        guard !stopped, let binding else { return }
        let will = (topicName: settings.stateTopic,
                    payload: ByteBuffer(data: binding.statePayload(online: false, extra: ["reason": "will"])),
                    qos: MQTTQoS.atLeastOnce, retain: true, properties: MQTTProperties())
        client.v5.connect(cleanStart: false, properties: [.sessionExpiryInterval(sessionExpirySeconds)], will: will)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let ack):
                    self.log("mqtt: connected to \(self.settings.host):\(self.settings.port) as \(self.settings.clientID) (sessionPresent=\(ack.sessionPresent), reason=\(ack.reason))")
                    self.onConnected()
                case .failure(let error):
                    self.log("mqtt: connect failed: \(error)")
                    self.scheduleReconnect()
                }
            }
    }

    private func onConnected() {
        setConnected(true)
        reconnectDelay = 1
        client.v5.subscribe(to: [MQTTSubscribeInfoV5(topicFilter: settings.commandTopic, qos: .atLeastOnce)])
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let ack): self.log("mqtt: subscribed \(self.settings.commandTopic) reasons=\(ack.reasons)")
                case .failure(let error): self.log("mqtt: subscribe failed: \(error)")
                }
            }
        if let binding {
            client.v5.publish(to: settings.stateTopic, payload: ByteBuffer(data: binding.statePayload(online: true, extra: ["pid": Int(ProcessInfo.processInfo.processIdentifier)])),
                              qos: .atLeastOnce, retain: true)
                .whenFailure { [weak self] error in self?.log("mqtt: state publish failed: \(error)") }
        }
        startPump()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        log("mqtt: reconnecting in \(Int(delay)) s")
        pumpQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, !self.isConnected else { return }
            self.connect()
        }
    }

    private func setConnected(_ value: Bool) {
        stateLock.lock(); connected = value; stateLock.unlock()
    }

    // MARK: Inbound commands

    private func inbound(_ info: MQTTPublishInfo) {
        guard info.topicName == settings.commandTopic else { return }
        var responseTopic: String?
        var correlation: Data?
        for property in info.properties {
            switch property {
            case .responseTopic(let topic): responseTopic = topic
            case .correlationData(let buffer): correlation = Data(buffer: buffer)
            default: break
            }
        }
        let payload = Data(buffer: info.payload)
        commandQueue.async { [weak self] in
            guard let self, let binding = self.binding else { return }
            do {
                _ = try binding.handleCommand(payload: payload, responseTopic: responseTopic, correlationData: correlation)
            } catch {
                self.log("mqtt: command handling failed: \(error)")
            }
        }
    }

    // MARK: Outbound

    public func publish(_ message: OutboundMessage) throws {
        var properties = MQTTProperties()
        if let correlation = message.correlationData { properties.append(.correlationData(ByteBuffer(data: correlation))) }
        for (key, value) in message.userProperties { properties.append(.userProperty(key, value)) }
        let qos: MQTTQoS = message.qos >= 2 ? .exactlyOnce : (message.qos == 1 ? .atLeastOnce : .atMostOnce)
        _ = try client.v5.publish(to: message.topic, payload: ByteBuffer(data: message.payload), qos: qos,
                                  retain: message.retain, properties: properties).wait()
    }

    /// B52 readiness: one QoS 1 publish of a random nonce to `readinessTopic`, waiting at most `timeout` for
    /// the broker's PUBACK. Categories only: notConnected, rejected (a reason code ≥ 0x80, e.g. ACL), timeout, network.
    public func probePublish(timeout: TimeInterval = 10) -> ReadinessProbeResult {
        let started = Date()
        guard isConnected else { return .failure("notConnected", latencyMs: 0) }
        let payload = ByteBuffer(data: Data(#"{"nonce":"\#(UUID().uuidString)"}"#.utf8))
        let future = client.v5.publish(to: settings.readinessTopic, payload: payload, qos: .atLeastOnce, retain: false)
        let outcome: Result<MQTTAckV5?, Error>? = ProbeWait.wait(timeout: timeout) { complete in future.whenComplete(complete) }
        let latency = ReadinessProbeResult.elapsedMs(since: started)
        switch outcome {
        case nil: return .failure("timeout", latencyMs: latency)
        case .success?: return .success(latencyMs: latency)
        case .failure(let error)?: return .failure(Self.probeCategory(error), latencyMs: latency)
        }
    }

    static func probeCategory(_ error: Error) -> String {
        guard let mqtt = error as? MQTTError else { return "network" }
        switch mqtt {
        case .reasonError: return "rejected"
        case .noConnection: return "notConnected"
        default: return "network"
        }
    }

    // MARK: Event pump

    private func startPump() {
        pumpTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected, let binding = self.binding else { return }
            do {
                let n = try binding.pumpEvents()
                if n > 0 { self.log("mqtt: published \(n) event(s)") }
            } catch {
                self.log("mqtt: event pump failed: \(error)")
            }
        }
        timer.resume()
        pumpTimer = timer
    }
}

public extension MQTTSettings {
    /// `~/Library/Application Support/imctl/mqtt.json`
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imctl", isDirectory: true).appendingPathComponent("mqtt.json")
    }
}
