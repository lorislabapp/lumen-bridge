import Foundation
import FrigateKit
import MQTTNIO
import NIOCore
import NIOPosix
import NIOTransportServices
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
        let subLabel: String?
        let stationary: Bool?
        let hasClip: Bool
        let recognizedPlate: String?
        let reviewID: String?
        let reviewSeverity: String?

        enum Kind: Sendable, Equatable {
            /// Detection just started — fires the user-visible notification
            /// path and writes the FrigateEvent CKRecord with snapshot.
            case new
            /// Detection ended and Frigate's clip is available — used by the
            /// coordinator to backfill the `clip` CKAsset on the existing
            /// record (only if clip-upload is enabled in Settings).
            case end
        }

        init(
            id: String,
            camera: String,
            label: String,
            zones: [String],
            topScore: Double,
            startTime: Date,
            kind: Kind,
            subLabel: String? = nil,
            stationary: Bool? = nil,
            hasClip: Bool = false,
            recognizedPlate: String? = nil,
            reviewID: String? = nil,
            reviewSeverity: String? = nil
        ) {
            self.id = id
            self.camera = camera
            self.label = label
            self.zones = zones
            self.topScore = topScore
            self.startTime = startTime
            self.kind = kind
            self.subLabel = subLabel
            self.stationary = stationary
            self.hasClip = hasClip
            self.recognizedPlate = recognizedPlate
            self.reviewID = reviewID
            self.reviewSeverity = reviewSeverity
        }

        func withReview(id: String, severity: String) -> Self {
            Self(
                id: self.id,
                camera: camera,
                label: label,
                zones: zones,
                topScore: topScore,
                startTime: startTime,
                kind: kind,
                subLabel: subLabel,
                stationary: stationary,
                hasClip: hasClip,
                recognizedPlate: recognizedPlate,
                reviewID: id,
                reviewSeverity: severity
            )
        }
    }

    struct Config: Sendable, Equatable {
        var host: String
        var port: Int = 1883
        var topic: String = "frigate/events"
        var reviewTopic: String = "frigate/reviews"
        var username: String?
        var password: String?
        var clientIdentifier: String = "lumen-bridge-\(UUID().uuidString.prefix(8))"
        /// Encrypted MQTT (usually port 8883). Uses Apple's Network.framework
        /// TLS, which validates the broker certificate against the system
        /// trust store; there is no "accept any certificate" mode.
        var useTLS: Bool = false
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
    private static let reviewClaimsKey = "lumenbridge.reviewClaims.v1"
    private var reviewCorrelator = FrigateReviewCorrelator(
        restoredClaims: UserDefaults.standard.stringArray(forKey: reviewClaimsKey) ?? []
    )

    /// Latest JPEG snapshot per `(camera, label)` published by Frigate on
    /// `frigate/<camera>/<label>/snapshot`. Used to attach a preview to
    /// each FrigateEvent CKRecord at persist time so the iOS notification
    /// can show a thumbnail.
    private var snapshotsByCameraLabel: [String: Data] = [:]
    /// Cap the snapshot cache so we don't grow unbounded if Frigate
    /// publishes many camera/label combos. ~5MB at 256KB/snap is plenty.
    private static let maxCachedSnapshots = 20
    private static let maxSnapshotBytes = 8 * 1_024 * 1_024
    private static let maxEventPayloadBytes = 256 * 1_024

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

    /// Called on the main actor for every valid `new`/`update`/`end`
    /// message (zones, sub label, end time). Feeds the mailbox visit
    /// detector; it is not filtered by the review correlator.
    var onObservation: (@MainActor @Sendable (MailboxObservation) -> Void)?

    /// Called on the main actor on every connection state transition.
    var onConnectionChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Camera names from `frigate/stats` (sent about every minute, even when
    /// nothing is detected), so HomeKit sensors exist before any event.
    var onCameras: (@MainActor @Sendable ([String]) -> Void)?

    func setOnCameras(_ callback: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.onCameras = callback
    }

    // MARK: - Lifecycle

    func configure(_ config: Config) {
        self.config = config
    }

    func setOnEvent(_ callback: @escaping @MainActor @Sendable (Event) -> Void) {
        self.onEvent = callback
    }

    func setOnObservation(_ callback: @escaping @MainActor @Sendable (MailboxObservation) -> Void) {
        self.onObservation = callback
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
            password: config.password,
            useSSL: config.useTLS
        )

        // TLS goes through Network.framework (NIOTransportServices) so the
        // certificate check is the system's. Plain MQTT keeps the existing
        // POSIX event loop.
        let group: any EventLoopGroup = config.useTLS
            ? NIOTSEventLoopGroup.singleton
            : MultiThreadedEventLoopGroup.singleton
        let client = MQTTClient(
            host: config.host,
            port: config.port,
            identifier: config.clientIdentifier,
            eventLoopGroupProvider: .shared(group),
            logger: nil,
            configuration: mqttConfig
        )

        // MQTTClient.deinit requires the client session to be shut down before
        // deallocation. The process-wide NIO singleton remains shared across
        // reconnects; only this client session is drained on failure.
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
                .init(topicFilter: config.reviewTopic, qos: .atLeastOnce),
                .init(topicFilter: "frigate/+/+/snapshot", qos: .atMostOnce),
                .init(topicFilter: "frigate/stats", qos: .atMostOnce),
                // Retained per-camera state: names arrive right on connect,
                // even when nothing is detected (night, quiet street).
                .init(topicFilter: "frigate/+/detect/state", qos: .atMostOnce),
            ])
            logger.info("subscribed to events, reviews, snapshots, stats and camera states")
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
        let reviewTopic = config.reviewTopic
        let callback = onEvent
        let observationCallback = onObservation
        let camerasCallback = onCameras
        let listener = client.createPublishListener()
        listenerTask = Task { [weak self] in
            for await result in listener {
                switch result {
                case .success(let packet):
                    await self?.noteTopic(packet.topicName)
                    if packet.topicName == topic {
                        guard packet.payload.readableBytes <= Self.maxEventPayloadBytes else {
                            logger.warning("discarded oversized Frigate event payload")
                            continue
                        }
                        if let observationCallback {
                            var copy = packet.payload
                            if let data = copy.readData(length: copy.readableBytes),
                               let observation = MailboxObservation.decode(from: data) {
                                await MainActor.run { observationCallback(observation) }
                            }
                        }
                        if let event = Self.decodeEvent(from: packet.payload) {
                            if event.kind == .end {
                                if let callback { await MainActor.run { callback(event) } }
                            } else if let self {
                                let ready = await self.correlate(event: event)
                                for correlated in ready {
                                    if let callback { await MainActor.run { callback(correlated) } }
                                }
                            }
                        }
                    } else if packet.topicName == reviewTopic {
                        guard packet.payload.readableBytes <= Self.maxEventPayloadBytes else {
                            logger.warning("discarded oversized Frigate review payload")
                            continue
                        }
                        if let review = Self.decodeReview(from: packet.payload), let self {
                            let ready = await self.correlate(review: review)
                            for correlated in ready {
                                if let callback { await MainActor.run { callback(correlated) } }
                            }
                        }
                    } else if let camera = Self.cameraFromStateTopic(packet.topicName) {
                        if let camerasCallback { await MainActor.run { camerasCallback([camera]) } }
                    } else if packet.topicName == "frigate/stats" {
                        guard let camerasCallback, packet.payload.readableBytes <= 512 * 1024 else { continue }
                        var copy = packet.payload
                        if let data = copy.readData(length: copy.readableBytes) {
                            let names = Self.decodeStatsCameras(from: data)
                            if !names.isEmpty { await MainActor.run { camerasCallback(names) } }
                        }
                    } else if let parsed = Self.parseSnapshotTopic(packet.topicName) {
                        guard packet.payload.readableBytes <= Self.maxSnapshotBytes else {
                            logger.warning("discarded oversized Frigate snapshot")
                            continue
                        }
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

    private func correlate(event: Event) -> [Event] {
        reviewCorrelator.ingest(event: event)
    }

    private func correlate(review: FrigateReviewCorrelator.Review) -> [Event] {
        reviewCorrelator.ingest(review: review)
    }

    func completeReviewDelivery(_ event: Event, terminal: Bool) {
        reviewCorrelator.complete(event: event, terminal: terminal)
        guard terminal else { return }
        UserDefaults.standard.set(Array(reviewCorrelator.claimedKeys).sorted(), forKey: Self.reviewClaimsKey)
    }

    /// Stores a snapshot in the per-camera/label cache, evicting the oldest
    /// entry once we cross `maxCachedSnapshots` so we don't grow unbounded.
    private func cacheSnapshot(camera: String, label: String, data: Data) {
        guard data.count <= Self.maxSnapshotBytes else { return }
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
              parts[3] == "snapshot",
              !parts[1].isEmpty, parts[1].utf8.count <= 128,
              !parts[2].isEmpty, parts[2].utf8.count <= 128 else { return nil }
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
                /// Legacy/REST name. Frigate's MQTT payload carries
                /// `current_zones` + `entered_zones` instead.
                let zones: [String]?
                let current_zones: [String]?
                let entered_zones: [String]?
                let top_score: Double
                let start_time: Double
                let stationary: Bool?
                let sub_label: FlexibleSubLabel?
                let has_clip: Bool?
                let data: EventData?
                struct EventData: Decodable {
                    let recognized_license_plate: String?
                }
            }
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            // Honor `new` (initial detection) AND `end` (finalised
            // recording). The handler distinguishes via the `kind` field
            // — only `new` fires a notification; `end` triggers a clip
            // backfill on the CKRecord that `new` already created.
            guard let a = wire.after else { return nil }
            // Zones the object has been in during this event (entered keeps
            // history, current adds the live ones), de-duplicated in order.
            var seenZones = Set<String>()
            let zones = ((a.zones ?? []) + (a.entered_zones ?? []) + (a.current_zones ?? []))
                .filter { seenZones.insert($0).inserted }
            guard Self.isValidIdentifier(a.id, maxBytes: 128),
                  Self.isValidName(a.camera), Self.isValidName(a.label),
                  zones.count <= 64,
                  zones.allSatisfy({ Self.isValidName($0) }),
                  a.top_score.isFinite, (0...1).contains(a.top_score),
                  a.start_time.isFinite else { return nil }
            let kind: Event.Kind
            switch wire.type {
            case "new":  kind = .new
            case "end":  kind = .end
            default:     return nil
            }
            return Event(
                id: a.id,
                camera: a.camera,
                label: a.label,
                zones: zones,
                topScore: a.top_score,
                startTime: Date(timeIntervalSince1970: a.start_time),
                kind: kind,
                subLabel: a.sub_label?.name,
                stationary: a.stationary,
                hasClip: a.has_clip ?? false,
                recognizedPlate: a.data?.recognized_license_plate
            )
        } catch {
            logger.warning("failed to decode event: \(error.localizedDescription)")
            return nil
        }
    }

    /// Decodes the same `frigate/events` payload as a full object transition
    /// for sequence engines. Invalid or partial payloads return nil.
    static func decodeTransition(from buffer: ByteBuffer) -> FrigateTrackedTransition? {
        var buffer = buffer
        guard let data = buffer.readData(length: buffer.readableBytes) else { return nil }
        return decodeTransition(from: data)
    }

    static func decodeTransition(from data: Data) -> FrigateTrackedTransition? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let transition = try? decoder.decode(FrigateTrackedTransition.self, from: data),
              transition.valid else { return nil }
        return transition
    }

    /// Diagnostics: first message seen per topic family (first two
    /// segments), logged once, bounded — answers "is anything arriving?".
    private var seenTopicFamilies: Set<String> = []
    private(set) var messageCount = 0

    private func noteTopic(_ topic: String) {
        messageCount += 1
        guard seenTopicFamilies.count < 40 else { return }
        let family = topic.split(separator: "/").prefix(2).joined(separator: "/")
        if seenTopicFamilies.insert(family).inserted {
            logger.info("first MQTT message on \(family, privacy: .public)")
        }
    }

    /// `frigate/<camera>/detect/state` → camera name.
    static func cameraFromStateTopic(_ topic: String) -> String? {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "frigate", parts[2] == "detect", parts[3] == "state" else { return nil }
        let camera = String(parts[1])
        return isValidName(camera) ? camera : nil
    }

    /// Camera names in a `frigate/stats` payload (`cameras` object keys).
    static func decodeStatsCameras(from data: Data) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cameras = json["cameras"] as? [String: Any] else { return [] }
        return cameras.keys.filter { isValidName($0) }.sorted().prefix(64).map { $0 }
    }

    /// Test seam: decode a raw `frigate/events` payload into the event model.
    static func decodeEvent(from data: Data) -> Event? {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return decodeEvent(from: buffer)
    }

    private static func isValidIdentifier(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
        }
    }

    private static func isValidName(_ value: String) -> Bool {
        isValidIdentifier(value, maxBytes: 128)
    }

    private static func decodeReview(from buffer: ByteBuffer) -> FrigateReviewCorrelator.Review? {
        var buffer = buffer
        guard let data = buffer.readData(length: buffer.readableBytes) else { return nil }
        struct Wire: Decodable {
            let type: String
            let after: Inner?
            struct Inner: Decodable {
                let id: String
                let severity: String
                let camera: String?
                let start_time: Double?
                let data: ReviewData
                struct ReviewData: Decodable {
                    let detections: [String]
                }
            }
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard wire.type == "new" || wire.type == "update",
                  let review = wire.after,
                  Self.isValidIdentifier(review.id, maxBytes: 128),
                  review.severity == "alert" || review.severity == "detection",
                  !review.data.detections.isEmpty,
                  review.data.detections.count <= 256,
                  review.data.detections.allSatisfy({ Self.isValidIdentifier($0, maxBytes: 128) }) else { return nil }
            return FrigateReviewCorrelator.Review(
                id: review.id,
                severity: review.severity,
                camera: review.camera,
                startTime: review.start_time.map(Date.init(timeIntervalSince1970:)),
                detectionIDs: Array(review.data.detections.prefix(256))
            )
        } catch {
            logger.warning("failed to decode Review: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Frigate publishes `sub_label` either as a plain string or as
/// `[name, score]`. Anything else decodes to nil instead of failing the
/// whole event (which used to drop events with a recognised face).
struct FlexibleSubLabel: Decodable, Sendable, Equatable {
    let name: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            name = nil
        } else if let text = try? container.decode(String.self) {
            name = text
        } else if var array = try? decoder.unkeyedContainer() {
            name = try? array.decode(String.self)
        } else {
            name = nil
        }
    }
}
