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
        discovery.start()
    }

    func stop() async {
        discovery.stop()
        await mqtt.disconnect()
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
        await connectMQTT(host: found.host, port: found.port)
    }

    private func wireMQTT() {
        Task {
            await mqtt.setOnEvent { [weak self] event in
                Task { @MainActor in
                    await self?.handleEvent(event)
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
