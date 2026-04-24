import Foundation
import MQTTNIO
import NIOCore
import NIOPosix
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "FrigateMQTT")

/// Subscribes to `frigate/events` on a Mosquitto / EMQX / HA broker and emits
/// each parsed `new` event through `onEvent`. Actor-scoped so concurrent
/// reconnects + listener updates serialize cleanly.
///
/// Uses MQTTNIO (SwiftNIO-based) so it runs natively on any Apple platform
/// including tvOS — no Darwin-only APIs.
actor FrigateMQTTClient {
    // MARK: - Public types

    struct Event: Sendable, Equatable {
        let id: String
        let camera: String
        let label: String
        let zones: [String]
        let topScore: Double
        let startTime: Date
    }

    struct Config: Sendable, Equatable {
        var host: String
        var port: Int = 1883
        var topic: String = "frigate/events"
        var username: String?
        var password: String?
        var clientIdentifier: String = "lumen-bridge-\(UUID().uuidString.prefix(8))"
    }

    enum ClientError: Error {
        case notConfigured
    }

    // MARK: - Private state

    private var config: Config?
    private var client: MQTTClient?
    private var listenerTask: Task<Void, Never>?
    private(set) var isConnected: Bool = false

    /// Called on the main actor when a `new` Frigate event arrives.
    var onEvent: (@MainActor @Sendable (Event) -> Void)?

    // MARK: - Lifecycle

    func configure(_ config: Config) {
        self.config = config
    }

    func setOnEvent(_ callback: @escaping @MainActor @Sendable (Event) -> Void) {
        self.onEvent = callback
    }

    func connect() async throws {
        guard let config else { throw ClientError.notConfigured }

        await disconnect()

        let mqttConfig = MQTTClient.Configuration(
            version: .v3_1_1,
            keepAliveInterval: .seconds(30),
            connectTimeout: .seconds(10),
            userName: config.username,
            password: config.password
        )

        let client = MQTTClient(
            host: config.host,
            port: config.port,
            identifier: config.clientIdentifier,
            eventLoopGroupProvider: .createNew,
            logger: nil,
            configuration: mqttConfig
        )

        _ = try await client.connect()
        logger.info("connected to \(config.host):\(config.port)")

        _ = try await client.subscribe(to: [
            .init(topicFilter: config.topic, qos: .atLeastOnce)
        ])
        logger.info("subscribed to \(config.topic)")

        self.client = client
        self.isConnected = true

        // Listener loop — forward successful publishes to onEvent.
        let topic = config.topic
        let callback = onEvent
        let listener = client.createPublishListener()
        listenerTask = Task {
            for await result in listener {
                switch result {
                case .success(let packet):
                    guard packet.topicName == topic else { continue }
                    if let event = Self.decodeEvent(from: packet.payload) {
                        if let callback {
                            await MainActor.run { callback(event) }
                        }
                    }
                case .failure(let err):
                    logger.error("listener error: \(err.localizedDescription)")
                }
            }
        }
    }

    func disconnect() async {
        listenerTask?.cancel()
        listenerTask = nil
        if let client {
            try? await client.disconnect()
            try? await client.shutdown()
        }
        client = nil
        isConnected = false
    }

    // MARK: - Decoding

    /// Parses one Frigate `frigate/events` message. Only `type: "new"`
    /// messages produce a returned `Event` — updates and ends are ignored
    /// (they arrive for the same event ID and the push has already fired).
    private static func decodeEvent(from buffer: ByteBuffer) -> Event? {
        var buffer = buffer
        guard let data = buffer.readData(length: buffer.readableBytes) else { return nil }
        struct Wire: Decodable {
            let type: String
            let after: Inner?
            struct Inner: Decodable {
                let id: String
                let camera: String
                let label: String
                let zones: [String]?
                let top_score: Double
                let start_time: Double
                let stationary: Bool?
            }
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard wire.type == "new", let a = wire.after else { return nil }
            if a.stationary == true { return nil }
            if a.top_score < 0.5 { return nil }
            return Event(
                id: a.id,
                camera: a.camera,
                label: a.label,
                zones: a.zones ?? [],
                topScore: a.top_score,
                startTime: Date(timeIntervalSince1970: a.start_time)
            )
        } catch {
            logger.warning("failed to decode event: \(error.localizedDescription)")
            return nil
        }
    }
}
