import SwiftUI
import AppKit

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
            let triggerTestEvent = CommandLine.arguments.contains("--test-event")
            Task { @MainActor in
                await c.start()
                if triggerTestEvent {
                    // Give MQTT 6s to cache at least one frigate snapshot
                    // before firing the synthetic event.
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    await c.sendTestEvent()
                }
            }
            // First-launch onboarding. SwiftUI's Window scene doesn't
            // auto-open on app launch for a menu-bar (LSUIElement) app, so
            // we drive the window through AppKit. Fires only when the
            // versioned completion flag is missing.
            if UserDefaults.standard.bool(forKey: OnboardingView.completedKey) == false {
                Task { @MainActor in
                    // Tiny delay so coordinator's start() has time to set
                    // initial CloudKit / Bonjour state before the wizard
                    // reads it for the welcome screens.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    OnboardingWindowPresenter.shared.show(state: state, coordinator: c)
                }
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
                },
                onToggleHAP: { [coordinator] enabled in
                    await coordinator?.setHAPEnabled(enabled)
                },
                onToggleHomebridge: { [coordinator] enabled in
                    await coordinator?.setHomebridgeCamerasEnabled(enabled)
                }
            )
        }
        .windowResizability(.contentSize)

    }
}

/// Drives the onboarding window via AppKit because SwiftUI's Window scene
/// doesn't auto-open on app launch for a menu-bar (LSUIElement) app. The
/// presenter owns a single NSWindow + NSHostingController over time and
/// re-uses them if the user closes and re-opens the wizard.
@MainActor
final class OnboardingWindowPresenter {
    static let shared = OnboardingWindowPresenter()
    private var window: NSWindow?

    func show(state: BridgeState, coordinator: BridgeCoordinator?) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            state: state,
            onApplyManualConfig: { [weak coordinator] host, port, user, pass in
                await coordinator?.applyManualConfig(
                    host: host, port: port,
                    username: user, password: pass
                )
            },
            onSendTestEvent: { [weak coordinator] in
                await coordinator?.sendTestEvent()
            },
            onFinish: { [weak self] in
                self?.window?.close()
            }
        )
        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "Welcome to Lumen Bridge"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 640, height: 540))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
