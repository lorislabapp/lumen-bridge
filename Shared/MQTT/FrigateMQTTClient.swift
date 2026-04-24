import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "FrigateMQTT")

/// Subscribes to `frigate/events` on a Mosquitto / EMQX / HA broker and
/// emits each parsed event through `onEvent`. Kept as an actor so concurrent
/// incoming messages serialize cleanly.
///
/// Phase 3 skeleton — real MQTT wire protocol implementation lands in the
/// follow-up commit using MQTTNIO (Apple SwiftNIO-based client). For now the
/// shell exposes the contract the rest of the app can call against.
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

    // MARK: - Configuration

    struct Config: Sendable, Equatable {
        var host: String
        var port: Int = 1883
        var topic: String = "frigate/events"
        var username: String?
        var password: String?
    }

    // MARK: - State

    private var config: Config?
    private var connectionTask: Task<Void, Never>?
    private(set) var isConnected: Bool = false

    /// Called on the main actor when a `new` Frigate event arrives that passes
    /// basic validation. Downstream filters (zones, cooldowns, schedules) run
    /// in the CloudKit writer, not here.
    var onEvent: (@MainActor @Sendable (Event) -> Void)?

    // MARK: - Lifecycle

    func configure(_ config: Config) {
        self.config = config
    }

    func connect() async {
        guard let config else {
            logger.error("connect called without configure")
            return
        }
        logger.info("TODO: connect to \(config.host):\(config.port) topic=\(config.topic)")
        // Phase 3 follow-up: open NWConnection, send CONNECT packet, SUBSCRIBE,
        // parse PUBLISH payloads as Frigate webhook JSON. The wire-level work
        // will move into a dedicated MQTTNIO wrapper once the package is added
        // to the project.
        isConnected = false
    }

    func disconnect() async {
        connectionTask?.cancel()
        connectionTask = nil
        isConnected = false
    }
}
