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
    @NSApplicationDelegateAdaptor(BridgeSupportAppDelegate.self) private var supportDelegate
    @State private var bridgeState: BridgeState
    @State private var coordinator: BridgeCoordinator?

    /// Headless one-shot: if `--seed-schema` is in the launch arguments, the
    /// app writes one synthetic FrigateEvent to CloudKit (seeding the
    /// Development schema on first run), then exits 0 on success / 1 on
    /// failure. Used to bootstrap the schema without requiring a click.
    private static var isSeedMode: Bool {
        CommandLine.arguments.contains("--seed-schema")
    }

    /// Unit tests are hosted by this app. Never connect to MQTT, CloudKit or
    /// HomeKit while XCTest is running.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @MainActor init() {
        let state = BridgeState()
        _bridgeState = State(initialValue: state)

        if Self.isRunningTests {
            _coordinator = State(initialValue: nil)
        } else if Self.isSeedMode {
            let c = BridgeCoordinator(state: state)
            _coordinator = State(initialValue: c)
            Task { @MainActor in
                await c.seedSchemaAndQuit()
            }
        } else {
            BridgeSupport.recordLaunch()
            HubAvailabilityController.shared.start()
            // Start the coordinator at app launch — NOT lazily on popover
            // open. Without this, the menu-bar app sits dormant until the
            // user clicks ⚡ (which is rare), and meanwhile no events get
            // forwarded from MQTT to CloudKit. We want to be running 24/7.
            let c = BridgeCoordinator(state: state)
            _coordinator = State(initialValue: c)
            supportDelegate.onShutdown = { [weak c] in
                HubAvailabilityController.shared.stop()
                await c?.stop()
            }
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
                    if await coordinator?.sendTestEvent() == true { BridgeSupport.review.recordSuccessMoment() }
                }
            )
        } label: {
            MenuBarLabel(connected: bridgeState.isConnected)
        }
        .menuBarExtraStyle(.window)

        // Main window — sidebar-driven control panel for everything the
        // Bridge can do (Status / Frigate / iCloud / HomeKit Sensors /
        // HomeKit Cameras / Logs / About). Replaces the older one-form
        // SettingsView once Phase 5 lands and the surface area outgrows
        // a single scroll view.
        Window(MainWindow.appName, id: "lumenbridge-settings") {
            HubRootView(state: bridgeState, onSetup: {
                OnboardingWindowPresenter.shared.show(state: bridgeState, coordinator: coordinator)
            }) {
                MainWindow(
                    state: bridgeState,
                    coordinator: coordinator,
                    onApplyConnection: { [coordinator] host, port, user, pass in
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
                    },
                    onSendTestEvent: { [coordinator] in
                        if await coordinator?.sendTestEvent() == true { BridgeSupport.review.recordSuccessMoment() }
                    }
                )
            }
        }
        // Minimum size only: with `.contentSize` the window grew to the full
        // height of long pages (taller than the screen), which pushed the
        // sidebar rows under the window buttons. Pages scroll inside.
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)

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
    var isVisible: Bool { window?.isVisible == true }

    func show(state: BridgeState, coordinator: BridgeCoordinator?) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            state: state,
            coordinator: coordinator,
            onFinish: { [weak self] in
                self?.window?.close()
                MainWindowOpener.shared.open?()
            }
        )
        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        // App name from the bundle: "Lumen Hub" (Developer ID) or "Lumen Bridge".
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lumen Bridge"
        w.title = String(localized: "Welcome to \(appName)")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 820, height: 700))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu bar icon. It is always rendered, so it is where the app captures
/// `openWindow` for the app delegate: re-opening the app (Finder, Dock,
/// `open`) shows the main window even when the menu bar icon is hidden
/// behind the notch or other icons.
struct MenuBarLabel: View {
    let connected: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: connected ? "bolt.fill" : "bolt.slash")
            .onAppear {
                MainWindowOpener.shared.open = { [openWindow] in
                    openWindow(id: "lumenbridge-settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    var open: (() -> Void)?
}
