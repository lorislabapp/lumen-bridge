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
struct LumenBridgeApp: App {
    @State private var bridgeState = BridgeState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: bridgeState)
        } label: {
            Image(systemName: bridgeState.isConnected ? "bolt.fill" : "bolt.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
