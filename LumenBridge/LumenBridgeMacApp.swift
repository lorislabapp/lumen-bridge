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
    @State private var bridgeState: BridgeState
    @State private var coordinator: BridgeCoordinator?

    /// Headless one-shot: if `--seed-schema` is in the launch arguments, the
    /// app writes one synthetic FrigateEvent to CloudKit (seeding the
    /// Development schema on first run), then exits 0 on success / 1 on
    /// failure. Used to bootstrap the schema without requiring a click.
    private static var isSeedMode: Bool {
        CommandLine.arguments.contains("--seed-schema")
    }

    @MainActor init() {
        let state = BridgeState()
        _bridgeState = State(initialValue: state)

        if Self.isSeedMode {
            let c = BridgeCoordinator(state: state)
            _coordinator = State(initialValue: c)
            Task { @MainActor in
                await c.seedSchemaAndQuit()
            }
        } else {
            // Start the coordinator at app launch — NOT lazily on popover
            // open. Without this, the menu-bar app sits dormant until the
            // user clicks ⚡ (which is rare), and meanwhile no events get
            // forwarded from MQTT to CloudKit. We want to be running 24/7.
            let c = BridgeCoordinator(state: state)
            _coordinator = State(initialValue: c)
            Task { @MainActor in
                await c.start()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                state: bridgeState,
                coordinator: coordinator,
                onSendTestEvent: { [coordinator] in
                    await coordinator?.sendTestEvent()
                }
            )
        } label: {
            Image(systemName: bridgeState.isConnected ? "bolt.fill" : "bolt.slash")
        }
        .menuBarExtraStyle(.window)

        // Settings window — opened by the menu-bar "Settings…" button or
        // when the user picks "Settings…" from the popover. SwiftUI's
        // openWindow environment action targets it by id.
        Window("Lumen Bridge — Settings", id: "lumenbridge-settings") {
            SettingsView(
                state: bridgeState,
                onApply: { [coordinator] host, port, user, pass in
                    await coordinator?.applyManualConfig(
                        host: host, port: port,
                        username: user, password: pass
                    )
                }
            )
        }
        .windowResizability(.contentSize)
    }
}
