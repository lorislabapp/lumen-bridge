import SwiftUI

/// Lumen Bridge — Apple TV companion of the macOS menu-bar bridge.
///
/// Why ship on tvOS: the Apple TV 4K is typically always-on and ethernet-
/// connected, the single most stable "home server" many users already own.
/// Running the bridge here means users don't need a dedicated Mac or
/// Raspberry Pi. tvOS background execution is the key validation gate —
/// if it falls over, we focus on macOS only (see
/// `audit-output/roadmap-apple-native-bridge.md`, Phase 2 kill-switch).
///
/// This target shares all non-UI code (BridgeState, FrigateMQTTClient,
/// CloudKitBridge, FrigateDiscovery) with the macOS target via multi-target
/// membership of the `Shared/` source tree.
@main
struct LumenBridgeTVApp: App {
    @State private var bridgeState = BridgeState()
    @State private var coordinator: BridgeCoordinator?

    var body: some Scene {
        WindowGroup {
            TVHomeView(state: bridgeState)
                .task {
                    guard coordinator == nil else { return }
                    let c = BridgeCoordinator(state: bridgeState)
                    coordinator = c
                    await c.start()
                }
        }
    }
}
