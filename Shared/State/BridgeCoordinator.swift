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

    // MARK: -

    private let state: BridgeState
    private let discovery = FrigateDiscovery()
    private let mqtt = FrigateMQTTClient()
    private let cloudKit = CloudKitBridge()

    init(state: BridgeState) {
        self.state = state
    }

    func start() async {
        await refreshCloudKitStatus()
        wireDiscovery()
        wireMQTT()

        // Reconnect to the last known Frigate host immediately, in parallel
        // with starting Bonjour. If discovery surfaces a different host on
        // the same network later, handleDiscovered upgrades to it; if not,
        // the saved host wins.
        if let savedHost = UserDefaults.standard.string(forKey: Self.savedHostKey) {
            let savedPort = UserDefaults.standard.integer(forKey: Self.savedPortKey)
            let port = savedPort > 0 ? savedPort : 1883
            state.frigateHost = savedHost
            state.frigatePort = port
            await connectMQTT(host: savedHost, port: port)
        }
        discovery.start()
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
        await handleEvent(event)
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
        // Auto-pair the first discovery if we have none yet.
        guard state.frigateHost == nil else { return }
        state.frigateHost = found.host
        state.frigatePort = found.port
        UserDefaults.standard.set(found.host, forKey: Self.savedHostKey)
        UserDefaults.standard.set(found.port, forKey: Self.savedPortKey)
        await connectMQTT(host: found.host, port: found.port)
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

    private func connectMQTT(host: String, port: Int) async {
        let config = FrigateMQTTClient.Config(host: host, port: port)
        await mqtt.configure(config)
        do {
            try await mqtt.connect()
            state.mqttConnected = true
            logger.info("MQTT connected via discovered host \(host):\(port)")
        } catch {
            state.mqttConnected = false
            logger.error("MQTT connect failed: \(error.localizedDescription)")
        }
    }

    private func handleEvent(_ event: FrigateMQTTClient.Event) async {
        state.eventsReceived += 1
        state.lastEventAt = Date()
        do {
            try await cloudKit.persist(event: event)
            state.eventsForwarded += 1
            logger.info("persisted event \(event.id)")
        } catch {
            logger.error("CloudKit persist failed for \(event.id): \(error.localizedDescription)")
        }
    }
}
