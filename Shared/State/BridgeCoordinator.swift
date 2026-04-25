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
    private static let savedPassKey = "lumenbridge.frigate.mqtt_pass"
    /// True after the user has explicitly entered host details. When true,
    /// Bonjour discoveries do NOT auto-replace the configured host — only the
    /// user can override their own choice.
    private static let manualConfigKey = "lumenbridge.frigate.manual"
    /// Opt-in flag for the Phase 5 HomeKit bridge. Off by default so the
    /// Bridge stays focused on notifications until the user explicitly
    /// turns HomeKit on in Settings or onboarding.
    static let hapEnabledKey = "lumenbridge.hap.enabled"

    // MARK: -

    private let state: BridgeState
    private let discovery = FrigateDiscovery()
    private let mqtt = FrigateMQTTClient()
    private let cloudKit = CloudKitBridge()
    #if os(macOS)
    private let hap: HAPBridgeManager
    #endif

    init(state: BridgeState) {
        self.state = state
        #if os(macOS)
        self.hap = HAPBridgeManager(state: state)
        #endif
    }

    func start() async {
        await refreshCloudKitStatus()
        wireDiscovery()
        wireMQTT()
        #if os(macOS)
        // HomeKit is opt-in for Phase 5. Boot the HAP server only if the
        // user has flipped the flag (via Settings or onboarding).
        if UserDefaults.standard.bool(forKey: Self.hapEnabledKey) {
            await hap.start()
        }
        #endif

        // Reconnect to the last known Frigate host immediately, in parallel
        // with starting Bonjour. If discovery surfaces a different host on
        // the same network later, handleDiscovered upgrades to it; if not,
        // the saved host wins.
        let defaults = UserDefaults.standard
        if let savedHost = defaults.string(forKey: Self.savedHostKey) {
            let savedPort = defaults.integer(forKey: Self.savedPortKey)
            let port = savedPort > 0 ? savedPort : 1883
            let user = defaults.string(forKey: Self.savedUserKey)
            let pass = defaults.string(forKey: Self.savedPassKey)
            state.frigateHost = savedHost
            state.frigatePort = port
            state.mqttUsername = user
            state.mqttPassword = pass
            await connectMQTT(host: savedHost, port: port, username: user, password: pass)
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
        defaults.set(password, forKey: Self.savedPassKey)
        defaults.set(true, forKey: Self.manualConfigKey)

        state.frigateHost = trimmedHost
        state.frigatePort = port
        state.mqttUsername = username
        state.mqttPassword = password
        state.lastMQTTError = nil

        await mqtt.disconnect()
        await connectMQTT(host: trimmedHost, port: port, username: username, password: password)
    }

    /// True if the user has entered host details explicitly (vs auto-paired
    /// via Bonjour). Used to decide whether to show the onboarding CTA.
    var hasManualConfig: Bool {
        UserDefaults.standard.bool(forKey: Self.manualConfigKey)
    }

    func stop() async {
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
            startTime: Date()
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
    func sendTestEvent() async {
        let id = "test-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let event = FrigateMQTTClient.Event(
            id: id,
            camera: "test_camera",
            label: "person",
            zones: ["entry"],
            topScore: 0.92,
            startTime: Date()
        )
        // For test events the camera/label is synthetic so latestSnapshot
        // returns nil. Try to attach ANY cached snapshot so the user can
        // verify the CKAsset path end-to-end without waiting for a real
        // detection on a matching camera.
        state.eventsReceived += 1
        state.lastEventAt = Date()
        let snapshot = await mqtt.anyCachedSnapshot()?.data
        do {
            try await cloudKit.persist(event: event, snapshot: snapshot)
            state.eventsForwarded += 1
            logger.info("test event \(id) persisted (\(snapshot != nil ? "with snapshot" : "no snapshot"))")
        } catch {
            logger.error("test event persist failed: \(error.localizedDescription)")
        }
    }

    // MARK: -

    private func refreshCloudKitStatus() async {
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
        Task {
            await mqtt.setOnEvent { [weak self] event in
                Task { @MainActor in
                    await self?.handleEvent(event)
                }
            }
            await mqtt.setOnConnectionChange { [weak self] connected in
                Task { @MainActor in
                    self?.state.mqttConnected = connected
                }
            }
        }
    }

    private func connectMQTT(host: String, port: Int, username: String?, password: String?) async {
        let config = FrigateMQTTClient.Config(
            host: host,
            port: port,
            username: username?.isEmpty == false ? username : nil,
            password: password?.isEmpty == false ? password : nil
        )
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
        state.eventsReceived += 1
        state.lastEventAt = Date()
        // Pull the most-recent snapshot Frigate published for this
        // camera+label off the MQTT actor's cache. May be nil for the
        // very first event of a session before any snapshot has been
        // published — that's fine, the record persists without preview.
        let snapshot = await mqtt.latestSnapshot(camera: event.camera, label: event.label)
        do {
            try await cloudKit.persist(event: event, snapshot: snapshot)
            state.eventsForwarded += 1
            if snapshot != nil {
                logger.info("persisted event \(event.id) with snapshot")
            } else {
                logger.info("persisted event \(event.id) (no snapshot yet)")
            }
        } catch {
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
        #endif
    }
}
