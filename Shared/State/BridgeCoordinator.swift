import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Coordinator")

/// Wires all the moving pieces into one lifecycle:
///   Discovery → (user picks / auto-first) → MQTT configure + connect →
///   each event → CloudKit persist → bump BridgeState counters.
///
/// Run on @MainActor so every UI update on BridgeState happens on the same
/// actor the SwiftUI views observe from. The heavier work (MQTT loop, CloudKit
/// writes) lives inside child actors (FrigateMQTTClient, CloudKitBridge).
@MainActor
final class BridgeCoordinator {
    // MARK: - UserDefaults keys

    /// Last known good Frigate host/port. Survives restarts so the bridge
    /// reconnects immediately on next launch instead of waiting for Bonjour.
    private static let savedHostKey = "lumenbridge.frigate.host"
    private static let savedPortKey = "lumenbridge.frigate.port"
    private static let savedUserKey = "lumenbridge.frigate.mqtt_user"
    /// True after the user has explicitly entered host details. When true,
    /// Bonjour discoveries do NOT auto-replace the configured host — only the
    /// user can override their own choice.
    private static let manualConfigKey = "lumenbridge.frigate.manual"
    /// Opt-in flag for the Phase 5 HomeKit bridge. Off by default so the
    /// Bridge stays focused on notifications until the user explicitly
    /// turns HomeKit on in Settings or onboarding.
    static let hapEnabledKey = "lumenbridge.hap.enabled"
    /// Phase 4 v0.2 — opt-in flag to upload the MP4 clip when Frigate
    /// finalises a detection. OFF by default because clips are 1-10 MB
    /// each and quickly fill iCloud private storage.
    static let clipUploadEnabledKey = "lumenbridge.clip_upload_enabled"
    /// Frigate web/API URL — used by both the Homebridge sidecar (macOS-
    /// only) AND the clip-fetch path (cross-platform). Defined here so
    /// both targets reference the same key.
    static let frigateWebURLKey = "lumenbridge.homebridge.frigate_web_url"

    // MARK: -

    private let state: BridgeState
    private let discovery = FrigateDiscovery()
    private let mqtt = FrigateMQTTClient()
    private let cloudKit = CloudKitBridge()
    private let configSync = BridgeConfigSync()
    private let automationAuthority = AutomationPolicyAuthority()
    private var automationAckTask: Task<Void, Never>?
    private var isStopping = false
    #if os(macOS)
    private let hap: HAPBridgeManager
    private let homebridge: HomebridgeManager
    #endif

    init(state: BridgeState) {
        self.state = state
        #if os(macOS)
        self.hap = HAPBridgeManager(state: state)
        self.homebridge = HomebridgeManager(state: state)
        #endif
    }

    func start() async {
        await refreshCloudKitStatus()
        guard !isStopping else { return }
        _ = automationAuthority.refreshAndAcknowledge()
        automationAckTask?.cancel()
        automationAckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 21_600_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                _ = self.automationAuthority.refreshAndAcknowledge()
            }
        }
        wireDiscovery()
        wireMQTT()
        await applyZoneAlerts(ZoneAlertStore.load())
        #if os(macOS)
        // HomeKit is opt-in for Phase 5. Boot the HAP server only if the
        // user has flipped the flag (via Settings or onboarding).
        if UserDefaults.standard.bool(forKey: Self.hapEnabledKey) {
            await hap.start()
            await hap.syncZoneDoorbells(zoneAlerts.filter(\.enabled).map { ($0.id, $0.name) })
        }
        if !isStopping, UserDefaults.standard.bool(forKey: HomebridgeManager.camerasEnabledKey) {
            await homebridge.start()
        }
        #endif

        // Subscribe to remote KVS updates so a config change on the macOS
        // Bridge propagates to the tvOS Bridge (and vice-versa) within
        // seconds without manual re-entry.
        configSync.observeRemoteChanges { [weak self] cfg in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applyManualConfig(
                    host: cfg.host, port: cfg.port,
                    username: cfg.username, password: cfg.password
                )
            }
        }

        // Reconnect to the last known Frigate host immediately, in parallel
        // with starting Bonjour. If discovery surfaces a different host on
        // the same network later, handleDiscovered upgrades to it; if not,
        // the saved host wins.
        let defaults = UserDefaults.standard
        if let savedHost = defaults.string(forKey: Self.savedHostKey) {
            let savedPort = defaults.integer(forKey: Self.savedPortKey)
            let port = savedPort > 0 ? savedPort : 1883
            let user = defaults.string(forKey: Self.savedUserKey)
            let pass = MQTTCredentialsKeychain.get()
            state.frigateHost = savedHost
            state.frigatePort = port
            state.mqttUsername = user
            state.mqttPassword = pass
            await connectMQTT(host: savedHost, port: port, username: user, password: pass)
        } else if let kvs = configSync.current {
            // No local config (typical on a fresh tvOS install) but iCloud
            // KVS has a config from a sibling Bridge — use it directly.
            state.frigateHost = kvs.host
            state.frigatePort = kvs.port
            state.mqttUsername = kvs.username
            state.mqttPassword = kvs.password
            await connectMQTT(host: kvs.host, port: kvs.port,
                              username: kvs.username, password: kvs.password)
        }
        discovery.start()
    }

    /// Apply user-entered Frigate connection details. Persisted across
    /// launches and immediately tested. The `manualConfig` flag keeps
    /// future Bonjour discoveries from silently replacing what the user
    /// explicitly chose.
    func applyManualConfig(host: String, port: Int, username: String?, password: String?) async {
        // Be forgiving — users paste URLs from browser address bars.
        // Strip http(s):// scheme, any path component, and the inline port
        // (we treat the explicit `port` argument as authoritative).
        var trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let urlScheme = trimmedHost.range(of: "://") {
            trimmedHost = String(trimmedHost[urlScheme.upperBound...])
        }
        if let slash = trimmedHost.firstIndex(of: "/") {
            trimmedHost = String(trimmedHost[..<slash])
        }
        if let colon = trimmedHost.firstIndex(of: ":") {
            trimmedHost = String(trimmedHost[..<colon])
        }
        guard !trimmedHost.isEmpty, port > 0, port <= 65535 else {
            state.lastMQTTError = "Invalid host or port"
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(trimmedHost, forKey: Self.savedHostKey)
        defaults.set(port, forKey: Self.savedPortKey)
        defaults.set(username, forKey: Self.savedUserKey)
        // Password persistence is Keychain-only. Explicitly purge the old
        // plaintext defaults key in case this install predates migration.
        defaults.removeObject(forKey: BridgeConfigSync.legacyLocalPassKey)
        defaults.set(true, forKey: Self.manualConfigKey)

        state.frigateHost = trimmedHost
        state.frigatePort = port
        state.mqttUsername = username
        state.mqttPassword = password
        state.lastMQTTError = nil

        // Mirror to iCloud KVS so a sibling Bridge (e.g. tvOS under the
        // same Apple ID) can pick up the config without manual re-entry.
        configSync.push(host: trimmedHost, port: port, username: username, password: password)

        await mqtt.disconnect()
        await connectMQTT(host: trimmedHost, port: port, username: username, password: password)
    }

    /// True if the user has entered host details explicitly (vs auto-paired
    /// via Bonjour). Used to decide whether to show the onboarding CTA.
    var hasManualConfig: Bool {
        UserDefaults.standard.bool(forKey: Self.manualConfigKey)
    }

    // MARK: - MQTT encryption

    static let mqttUseTLSKey = "lumenbridge.mqtt.use_tls"

    /// Turns encrypted MQTT on/off and reconnects with the saved host.
    func setMQTTUseTLS(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.mqttUseTLSKey)
        guard let host = state.frigateHost else { return }
        await mqtt.disconnect()
        let port = state.frigatePort ?? (enabled ? 8883 : 1883)
        await connectMQTT(host: host, port: port, username: state.mqttUsername,
                          password: state.mqttPassword)
    }

    // MARK: - Zone alerts (mailbox, gate, front door…)

    /// One monitor per enabled alert, keyed by alert id.
    private var monitors: [UUID: MailboxMonitor] = [:]
    private(set) var zoneAlerts: [ZoneAlert] = []

    /// Saves the owner's alerts and applies them immediately.
    func setZoneAlerts(_ alerts: [ZoneAlert]) async {
        ZoneAlertStore.save(alerts)
        await applyZoneAlerts(ZoneAlertStore.load())
    }

    private func applyZoneAlerts(_ alerts: [ZoneAlert]) async {
        zoneAlerts = alerts
        state.zoneAlerts = alerts
        let active = alerts.filter(\.enabled)
        monitors = monitors.filter { id, _ in active.contains { $0.id == id } }
        for alert in active {
            let monitor = monitors[alert.id] ?? MailboxMonitor()
            monitor.configure(alert.configuration)
            monitor.onVisit = { [weak self] visit in self?.handleVisit(visit, alert: alert) }
            monitors[alert.id] = monitor
        }
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: Self.hapEnabledKey) {
            await hap.syncZoneDoorbells(active.map { ($0.id, $0.name) })
        }
        #endif
    }

    /// Cameras announced by `frigate/stats`: known to the alert pickers and
    /// each gets its HomeKit motion sensor right away.
    private func learnCameras(_ cameras: [String]) {
        for camera in cameras where state.seenZones[camera] == nil {
            state.learn(camera: camera, zones: [], label: "person")
        }
        #if os(macOS)
        if state.hapStatus.isRunning {
            Task { @MainActor in
                for camera in cameras { await self.hap.ensureCameraAccessory(cameraName: camera) }
            }
        }
        #endif
    }

    private func feedZoneAlerts(_ observation: MailboxObservation) {
        let newCamera = state.seenZones[observation.camera] == nil
        state.learn(camera: observation.camera, zones: observation.zones, label: observation.label)
        #if os(macOS)
        // One HomeKit motion sensor per camera as soon as Frigate mentions it,
        // not only after that camera's first correlated detection.
        if newCamera, state.hapStatus.isRunning {
            let camera = observation.camera
            Task { @MainActor in await self.hap.ensureCameraAccessory(cameraName: camera) }
        }
        #endif
        for monitor in monitors.values { monitor.consume(observation) }
    }

    private func handleVisit(_ visit: MailboxMonitor.Visit, alert: ZoneAlert) {
        state.lastZoneVisits[alert.id] = visit.end
        logger.info("zone alert visit on \(visit.camera, privacy: .public)")
        #if os(macOS)
        // One chime only: the camera doorbell (with snapshot) when the
        // HomeKit cameras run, otherwise this alert's own doorbell.
        Task { @MainActor in
            if self.homebridge.isRunning {
                await self.homebridge.triggerDoorbell(camera: visit.camera)
            } else {
                await self.hap.ringZoneDoorbell(id: alert.id)
            }
        }
        #endif
        let review = reviewByEvent[visit.eventIDs[0]]
        Task { @MainActor in
            let outcome = await self.mailboxPush.send(visit: visit, review: review, alertName: alert.name,
                                                      zone: alert.configuration.mailboxZone)
            self.state.lastZonePushOutcome[alert.id] = String(describing: outcome)
            logger.info("zone alert push: \(String(describing: outcome), privacy: .public)")
        }
    }

    /// Frigate review linked to each recent event (from the correlator), so a
    /// mailbox visit can be pushed as that review. Bounded.
    private var reviewByEvent: [String: MailboxPushSender.ReviewLink] = [:]
    private var reviewOrder: [String] = []
    private let mailboxPush = MailboxPushSender()

    private func rememberReview(eventID: String, link: MailboxPushSender.ReviewLink) {
        if reviewByEvent[eventID] == nil { reviewOrder.append(eventID) }
        reviewByEvent[eventID] = link
        if reviewOrder.count > 256 {
            let drop = reviewOrder.removeFirst()
            reviewByEvent[drop] = nil
        }
    }

    #if os(macOS)
    /// Toggle the HomeKit bridge at runtime — flips the persisted opt-in
    /// flag and starts or stops the HAP server immediately so the user
    /// doesn't have to relaunch after toggling in Settings.
    func setHAPEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.hapEnabledKey)
        if enabled {
            await hap.start()
            await hap.syncZoneDoorbells(zoneAlerts.filter(\.enabled).map { ($0.id, $0.name) })
        } else {
            await hap.stop()
        }
    }

    /// Saves a checked Frigate web address and restarts the camera module
    /// so it picks it up (it used to keep its startup error).
    func setFrigateWebURL(_ url: String) async {
        UserDefaults.standard.set(url, forKey: HomebridgeManager.frigateWebURLKey)
        if UserDefaults.standard.bool(forKey: HomebridgeManager.camerasEnabledKey) {
            await homebridge.stop()
            if UserDefaults.standard.bool(forKey: HomebridgeManager.camerasEnabledKey) {
                await homebridge.start()
            }
        }
    }

    func checkHomeKitCameraSources() async { await homebridge.refreshCameraChecks() }

    /// Toggle the Homebridge sidecar that powers HomeKit camera streaming.
    /// Independent of `setHAPEnabled` — motion sensors and cameras can
    /// each be on/off independently.
    func setHomebridgeCamerasEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: HomebridgeManager.camerasEnabledKey)
        if enabled {
            await homebridge.start()
        } else {
            await homebridge.stop()
        }
    }
    #endif

    func stop() async {
        isStopping = true
        #if os(macOS)
        await homebridge.stop()
        await hap.stop()
        #endif
        automationAckTask?.cancel()
        automationAckTask = nil
        discovery.stop()
        await mqtt.disconnect()
    }

    // MARK: - Test event

    /// Headless schema seeder. Refreshes CloudKit account status, writes one
    /// synthetic FrigateEvent, then calls `exit()` so the app terminates
    /// without ever showing UI. Used when the binary is launched with
    /// `--seed-schema` to bootstrap the FrigateEvent record type in the
    /// Development environment without a click.
    func seedSchemaAndQuit() async {
        await refreshCloudKitStatus()
        guard state.cloudKitStatus == .available else {
            logger.error("seed-schema: CloudKit not available (\(String(describing: self.state.cloudKitStatus))) — aborting")
            exit(1)
        }
        let id = "seed-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let event = FrigateMQTTClient.Event(
            id: id,
            camera: "test_camera",
            label: "person",
            zones: ["entry"],
            topScore: 0.92,
            startTime: Date(),
            kind: .new,
            reviewID: id,
            reviewSeverity: "alert"
        )
        do {
            try await cloudKit.persist(event: event)
            logger.info("seed-schema: wrote \(id) to CloudKit ✓")
            exit(0)
        } catch {
            logger.error("seed-schema: persist failed — \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Manual entry point — writes a synthetic FrigateEvent to CloudKit
    /// without going through MQTT. Two purposes:
    ///   (1) Seed the FrigateEvent record type in the CloudKit schema on
    ///       first run, so the dashboard can promote Development → Production.
    ///   (2) Verify end-to-end push delivery (CKSubscription → APNs →
    ///       Lumen iOS BridgeNotificationPresenter) without needing a
    ///       running Frigate instance.
    @discardableResult
    func sendTestEvent() async -> Bool {
        #if os(macOS)
        state.notificationTestFailed = false
        #endif
        let id = "test-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let event = FrigateMQTTClient.Event(
            id: id,
            camera: "test_camera",
            label: "person",
            zones: ["entry"],
            topScore: 0.92,
            startTime: Date(),
            kind: .new,
            reviewID: id,
            reviewSeverity: "alert"
        )
        // For test events the camera/label is synthetic so latestSnapshot
        // returns nil. Try to attach ANY cached snapshot so the user can
        // verify the CKAsset path end-to-end without waiting for a real
        // detection on a matching camera.
        state.eventsReceived += 1
        state.lastEventAt = Date()
        _ = automationAuthority.refreshAndAcknowledge()
        let automationDecision: BridgeAutomationDecision?
        switch automationAuthority.evaluate(event: event) {
        case .passthrough:
            automationDecision = nil
        case .suppress(let reason):
            await mqtt.completeReviewDelivery(event, terminal: true)
            logger.info("suppressed event \(event.id) before CloudKit: \(reason, privacy: .public)")
            return false
        case .deliver(let decision):
            automationDecision = decision
        }
        let snapshot = await mqtt.anyCachedSnapshot()?.data
        do {
            try await cloudKit.persist(event: event, snapshot: snapshot, automationDecision: automationDecision)
            await mqtt.completeReviewDelivery(event, terminal: true)
            state.eventsForwarded += 1
            #if os(macOS)
            state.notificationTestSentAt = Date()
            #endif
            logger.info("test event \(id) persisted (\(snapshot != nil ? "with snapshot" : "no snapshot"))")
            return true
        } catch {
            #if os(macOS)
            state.notificationTestFailed = true
            #endif
            logger.error("test event persist failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: -

    func refreshCloudKitStatus() async {
        let status = await cloudKit.accountStatus()
        state.cloudKitStatus = status
    }

    private func wireDiscovery() {
        discovery.onFound = { [weak self] found in
            Task { @MainActor in
                await self?.handleDiscovered(found)
            }
        }
    }

    private func handleDiscovered(_ found: DiscoveredFrigate) async {
        if !state.discoveredInstances.contains(where: { $0.id == found.id }) {
            state.discoveredInstances.append(found)
        }
        // Never override a host the user has explicitly entered.
        if hasManualConfig { return }
        // Auto-pair the first discovery if we have none yet.
        guard state.frigateHost == nil else { return }
        state.frigateHost = found.host
        state.frigatePort = found.port
        UserDefaults.standard.set(found.host, forKey: Self.savedHostKey)
        UserDefaults.standard.set(found.port, forKey: Self.savedPortKey)
        await connectMQTT(host: found.host, port: found.port, username: nil, password: nil)
    }

    private func wireMQTT() {
        Task { [weak self] in
            guard let self else { return }
            await mqtt.setOnEvent { [weak self] event in
                Task { @MainActor in
                    await self?.handleEvent(event)
                }
            }
            await mqtt.setOnObservation { [weak self] observation in
                self?.feedZoneAlerts(observation)
            }
            await mqtt.setOnCameras { [weak self] cameras in
                self?.learnCameras(cameras)
            }
            await mqtt.setOnConnectionChange { [weak self] connected in
                Task { @MainActor in
                    self?.state.mqttConnected = connected
                    self?.monitors.values.forEach { $0.connectionChanged(connected: connected) }
                }
            }
        }
    }

    private func connectMQTT(host: String, port: Int, username: String?, password: String?) async {
        var config = FrigateMQTTClient.Config(
            host: host,
            port: port,
            username: username?.isEmpty == false ? username : nil,
            password: password?.isEmpty == false ? password : nil
        )
        config.useTLS = UserDefaults.standard.bool(forKey: Self.mqttUseTLSKey)
        state.mqttEncrypted = config.useTLS
        await mqtt.configure(config)
        do {
            try await mqtt.connect()
            state.mqttConnected = true
            state.lastMQTTError = nil
            logger.info("MQTT connected to \(host):\(port)")
        } catch {
            // NIOTSChannelError and friends crash inside `localizedDescription`
            // (Error metadata bridge bug seen in MQTTNIO 2.x on Swift 6).
            // Use String(describing:) which only inspects the type's own
            // CustomStringConvertible and never touches the bridged NSError.
            let safeMessage = String(describing: error)
            state.mqttConnected = false
            state.lastMQTTError = safeMessage
            logger.error("MQTT connect failed: \(safeMessage)")
        }
    }

    private func handleEvent(_ event: FrigateMQTTClient.Event) async {
        // `end` events backfill the clip on a record we already wrote at
        // `new` time. They never fire a notification or bump counters —
        // the original `new` did that.
        if event.kind == .end {
            await enrichWithClip(eventID: event.id, camera: event.camera)
            return
        }
        state.eventsReceived += 1
        state.lastEventAt = Date()
        if let reviewID = event.reviewID, let severity = event.reviewSeverity {
            rememberReview(eventID: event.id, link: .init(reviewID: reviewID, severity: severity,
                                                          topScore: event.topScore))
        }
        _ = automationAuthority.refreshAndAcknowledge()
        let automationDecision: BridgeAutomationDecision?
        switch automationAuthority.evaluate(event: event) {
        case .passthrough:
            automationDecision = nil
        case .suppress(let reason):
            await mqtt.completeReviewDelivery(event, terminal: true)
            logger.info("suppressed event \(event.id) before CloudKit: \(reason, privacy: .public)")
            return
        case .deliver(let decision):
            automationDecision = decision
        }
        // Pull the most-recent snapshot Frigate published for this
        // camera+label off the MQTT actor's cache. May be nil for the
        // very first event of a session before any snapshot has been
        // published — that's fine, the record persists without preview.
        let snapshot = await mqtt.latestSnapshot(camera: event.camera, label: event.label)
        do {
            try await cloudKit.persist(
                event: event,
                snapshot: snapshot,
                automationDecision: automationDecision
            )
            await mqtt.completeReviewDelivery(event, terminal: true)
            state.eventsForwarded += 1
            if snapshot != nil {
                logger.info("persisted event \(event.id) with snapshot")
            } else {
                logger.info("persisted event \(event.id) (no snapshot yet)")
            }
        } catch {
            await mqtt.completeReviewDelivery(event, terminal: false)
            logger.error("CloudKit persist failed for \(event.id): \(error.localizedDescription)")
        }
        #if os(macOS)
        // Mirror to HomeKit — adds the camera as an accessory the first
        // time we see it, then triggers the motion-detected characteristic
        // so the Home app surfaces a motion alert and HomePods chime.
        if state.hapStatus.isRunning {
            await hap.ensureCameraAccessory(cameraName: event.camera)
            await hap.reportMotion(cameraName: event.camera, detected: true)
        }
        // HomeKit cameras (Homebridge): pulse the camera's own motion sensor
        // so Apple Home shows the alert with that camera's snapshot.
        if homebridge.isRunning {
            await homebridge.triggerMotion(camera: event.camera)
        }
        #endif
    }

    /// Phase 4 v0.2 — when Frigate publishes an `end` event for a detection
    /// we already wrote at `new` time, fetch the finalised MP4 clip from
    /// Frigate's web API and update the existing CKRecord with a `clip`
    /// CKAsset. Gated behind `clipUploadEnabledKey` because clips are
    /// 1-10 MB and quickly fill iCloud free tier.
    private func enrichWithClip(eventID: String, camera: String) async {
        guard UserDefaults.standard.bool(forKey: Self.clipUploadEnabledKey) else { return }
        guard let webURL = UserDefaults.standard.string(forKey: Self.frigateWebURLKey),
              !webURL.isEmpty else {
            logger.info("clip enrich skipped — Frigate web URL not configured")
            return
        }
        guard let clipURL = URL(string: "\(webURL)/api/events/\(eventID)/clip.mp4") else { return }
        // Frigate finalises the clip a few seconds after the `end` event;
        // a brief wait avoids the 404 race.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        do {
            var request = URLRequest(url: clipURL)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.info("clip not ready for \(eventID) — leaving record snapshot-only")
                return
            }
            await cloudKit.attachClip(eventID: eventID, clipMP4: data)
            logger.info("attached clip for \(eventID) (\(data.count) bytes, camera=\(camera))")
        } catch {
            logger.warning("clip fetch failed for \(eventID): \(error.localizedDescription)")
        }
    }
}
