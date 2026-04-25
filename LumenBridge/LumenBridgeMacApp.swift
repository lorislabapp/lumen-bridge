import SwiftUI

/// Lumen Bridge — native macOS menu-bar app that bridges Frigate NVR (via
/// MQTT) to Apple's CloudKit, letting every Lumen install under the user's
/// Apple ID receive Frigate detection pushes natively with zero third-party
/// infrastructure.
///
/// Part of the Apple-native Bridge pivot (Phase 3). See the roadmap at
/// `audit-output/roadmap-apple-native-bridge.md` in the Lumen for Frigate
/// repo.
@main
struct LumenBridgeMacApp: App {
    @State private var bridgeState = BridgeState()
    @State private var coordinator: BridgeCoordinator?

    /// Headless one-shot: if `--seed-schema` is in the launch arguments, the
    /// app writes one synthetic FrigateEvent to CloudKit (seeding the
    /// Development schema on first run), then exits 0 on success / 1 on
    /// failure. Used to bootstrap the schema without requiring a click.
    private static var isSeedMode: Bool {
        CommandLine.arguments.contains("--seed-schema")
    }

    @MainActor init() {
        if Self.isSeedMode {
            // SwiftUI App.init runs on the main actor; launching a Task here
            // schedules the seeder on that actor and the body never has to
            // construct (we exit the process on success).
            let state = bridgeState
            Task { @MainActor in
                let c = BridgeCoordinator(state: state)
                await c.seedSchemaAndQuit()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                state: bridgeState,
                onSendTestEvent: { [coordinator] in
                    await coordinator?.sendTestEvent()
                }
            )
        } label: {
            Image(systemName: bridgeState.isConnected ? "bolt.fill" : "bolt.slash")
        }
        .menuBarExtraStyle(.window)
        .onChange(of: coordinator == nil) { _, _ in
            guard coordinator == nil else { return }
            let c = BridgeCoordinator(state: bridgeState)
            coordinator = c
            Task { await c.start() }
        }
    }
}
