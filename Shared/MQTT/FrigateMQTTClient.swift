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
///
/// Auto-reconnects on unexpected disconnects (network blip, Frigate restart,
/// broker restart) with exponential backoff capped at 30s. Manual `disconnect`
/// suppresses reconnect — the next `connect` call has to come from the user.
actor FrigateMQTTClient {
    // MARK: - Public types

    struct Event: Sendable, Equatable {
        let id: String
        let camera: String
        let label: String
        let zones: [String]
        let topScore: Double
        let startTime: Date
        let kind: Kind

        enum Kind: Sendable, Equatable {
            /// Detection just started — fires the user-visible notification
            /// path and writes the FrigateEvent CKRecord with snapshot.
            case new
            /// Detection ended and Frigate's clip is available — used by the
            /// coordinator to backfill the `clip` CKAsset on the existing
            /// record (only if clip-upload is enabled in Settings).
            case end
        }
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
    private var reconnectTask: Task<Void, Never>?
    private var stopRequested: Bool = false
    private var consecutiveReconnectFailures: Int = 0

    /// Latest JPEG snapshot per `(camera, label)` published by Frigate on
    /// `frigate/<camera>/<label>/snapshot`. Used to attach a preview to
    /// each FrigateEvent CKRecord at persist time so the iOS notification
    /// can show a thumbnail.
    private var snapshotsByCameraLabel: [String: Data] = [:]
    /// Cap the snapshot cache so we don't grow unbounded if Frigate
    /// publishes many camera/label combos. ~5MB at 256KB/snap is plenty.
    private static let maxCachedSnapshots = 20

    /// Latest snapshot for a given camera + label, if Frigate has published
    /// one in this session. Returned to the coordinator at event-persist
    /// time so it can attach as a CKAsset.
    func latestSnapshot(camera: String, label: String) -> Data? {
        snapshotsByCameraLabel["\(camera)/\(label)"]
    }

    /// Any cached snapshot — used by test-event flow so we can verify the
    /// snapshot/CKAsset path end-to-end even when Frigate hasn't published
    /// one for the synthetic camera/label pair yet.
    func anyCachedSnapshot() -> (cameraLabel: String, data: Data)? {
        guard let pair = snapshotsByCameraLabel.first else { return nil }
        return (pair.key, pair.value)
    }
    private(set) var isConnected: Bool = false {
        didSet {
            guard oldValue != isConnected else { return }
            let cb = onConnectionChange
            let nowConnected = isConnected
            if let cb {
                Task { await MainActor.run { cb(nowConnected) } }
            }
        }
    }

    /// Called on the main actor when a `new` Frigate event arrives.
    var onEvent: (@MainActor @Sendable (Event) -> Void)?

    /// Called on the main actor on every connection state transition.
    var onConnectionChange: (@MainActor @Sendable (Bool) -> Void)?

    // MARK: - Lifecycle

    func configure(_ config: Config) {
        self.config = config
    }

    func setOnEvent(_ callback: @escaping @MainActor @Sendable (Event) -> Void) {
        self.onEvent = callback
    }

    func setOnConnectionChange(_ callback: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onConnectionChange = callback
    }

    func connect() async throws {
        guard let config else { throw ClientError.notConfigured }
        stopRequested = false

        await teardownClient()

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

        // CRITICAL: MQTTClient.deinit asserts that the client was shut down
        // before deallocation (otherwise the embedded EventLoopGroup leaks
        // its thread). If `connect()` or `subscribe()` throws, the local
        // `client` would be released without shutdown → assertion crash.
        // Wrap the connect+subscribe in do/catch to clean up on failure.
        do {
            _ = try await client.connect()
            logger.info("connected to \(config.host):\(config.port)")

            // Subscribe to events AND to per-camera snapshot topics. Frigate
            // publishes raw JPEG bytes on `frigate/<camera>/<label>/snapshot`
            // whenever a detection updates — we cache the latest per
            // camera/label pair and attach it to the CKRecord at persist
            // time so the iOS notification can show a thumbnail.
            _ = try await client.subscribe(to: [
                .init(topicFilter: config.topic, qos: .atLeastOnce),
                .init(topicFilter: "frigate/+/+/snapshot", qos: .atMostOnce),
            ])
            logger.info("subscribed to \(config.topic) + frigate/+/+/snapshot")
        } catch {
            // Shutdown the half-constructed client so its EventLoopGroup
            // drains cleanly, then re-throw the original error.
            try? await client.shutdown()
            throw error
        }

        self.client = client
        self.isConnected = true
        self.consecutiveReconnectFailures = 0

        // Wire close listener for auto-reconnect on unexpected disconnects.
        client.addCloseListener(named: "auto-reconnect") { [weak self] _ in
            Task { await self?.handleUnexpectedClose() }
        }

        // Listener loop — events go to onEvent, snapshots are cached on
        // the actor for the coordinator to read at persist time.
        let topic = config.topic
        let callback = onEvent
        let listener = client.createPublishListener()
        listenerTask = Task { [weak self] in
            for await result in listener {
                switch result {
                case .success(let packet):
                    if packet.topicName == topic {
                        if let event = Self.decodeEvent(from: packet.payload) {
                            if let callback {
                                await MainActor.run { callback(event) }
                            }
                        }
                    } else if let parsed = Self.parseSnapshotTopic(packet.topicName) {
                        // Read JPEG bytes off the actor-isolated buffer.
                        var buf = packet.payload
                        if let bytes = buf.readData(length: buf.readableBytes) {
                            await self?.cacheSnapshot(camera: parsed.camera,
                                                     label: parsed.label,
                                                     data: bytes)
                        }
                    }
                case .failure(let err):
                    logger.error("listener error: \(err.localizedDescription)")
                }
            }
        }
    }

    /// Stores a snapshot in the per-camera/label cache, evicting the oldest
    /// entry once we cross `maxCachedSnapshots` so we don't grow unbounded.
    private func cacheSnapshot(camera: String, label: String, data: Data) {
        let key = "\(camera)/\(label)"
        snapshotsByCameraLabel[key] = data
        if snapshotsByCameraLabel.count > Self.maxCachedSnapshots {
            // Drop a non-deterministic key — fine because the freshly-cached
            // one is the one the next event will need; older ones can be
            // re-fetched from Frigate if/when needed.
            if let evict = snapshotsByCameraLabel.keys.first(where: { $0 != key }) {
                snapshotsByCameraLabel.removeValue(forKey: evict)
            }
        }
    }

    /// Parses a `frigate/<camera>/<label>/snapshot` topic. Returns nil for
    /// any other topic shape so events and snapshots don't cross-contaminate.
    private static func parseSnapshotTopic(_ topic: String) -> (camera: String, label: String)? {
        let parts = topic.split(separator: "/")
        guard parts.count == 4,
              parts[0] == "frigate",
              parts[3] == "snapshot" else { return nil }
        return (camera: String(parts[1]), label: String(parts[2]))
    }

    func disconnect() async {
        stopRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardownClient()
        isConnected = false
    }

    // MARK: - Auto-reconnect

    private func handleUnexpectedClose() async {
        // Ignore if the user asked us to stop, or if we already detached.
        guard !stopRequested else { return }
        guard isConnected else { return }
        logger.warning("MQTT connection closed unexpectedly — scheduling reconnect")
        isConnected = false
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let backoff = nextBackoffSeconds()
        consecutiveReconnectFailures += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        guard !stopRequested else { return }
        do {
            try await connect()
            logger.info("auto-reconnect succeeded")
        } catch {
            logger.error("auto-reconnect failed: \(error.localizedDescription) — backing off")
            // schedule the next attempt with longer backoff
            scheduleReconnect()
        }
    }

    private func nextBackoffSeconds() -> Double {
        // 1s, 2s, 4s, 8s, 16s, 30s (cap), 30s, ...
        let n = min(consecutiveReconnectFailures, 5)
        let base = pow(2.0, Double(n))
        return min(base, 30.0)
    }

    private func teardownClient() async {
        listenerTask?.cancel()
        listenerTask = nil
        if let client {
            client.removeCloseListener(named: "auto-reconnect")
            try? await client.disconnect()
            try? await client.shutdown()
        }
        client = nil
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
            // Honor `new` (initial detection) AND `end` (finalised
            // recording). The handler distinguishes via the `kind` field
            // — only `new` fires a notification; `end` triggers a clip
            // backfill on the CKRecord that `new` already created.
            guard let a = wire.after else { return nil }
            let kind: Event.Kind
            switch wire.type {
            case "new":  kind = .new
            case "end":  kind = .end
            default:     return nil
            }
            if a.stationary == true { return nil }
            if a.top_score < 0.5 { return nil }
            return Event(
                id: a.id,
                camera: a.camera,
                label: a.label,
                zones: a.zones ?? [],
                topScore: a.top_score,
                startTime: Date(timeIntervalSince1970: a.start_time),
                kind: kind
            )
        } catch {
            logger.warning("failed to decode event: \(error.localizedDescription)")
            return nil
        }
    }
}
