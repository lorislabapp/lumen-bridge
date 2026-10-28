import AppKit
import Foundation
import LorisLabsKit
import LorisReports
import SwiftUI
import UserNotifications
import ServiceManagement
import IOKit.pwr_mgt
import IOKit.ps

/// A host-only owner. Technical events contain closed enums, never BridgeState or MQTT data.
@MainActor
enum BridgeSupport {
    static let profile = FeedbackAppProfile(appID: "lumen-bridge", displayName: "Lumen Bridge", allowedFields: [])
    static let configuration = configuration(bundle: .main)
    static let client = FeedbackClient(profile: profile, configuration: configuration)
    static let review = SmartReviewPromptManager(bundleIdentifier: "com.lorislabapp.lumenbridge")
    static let notifications = SupportNotificationCoordinator(client: client,
        topic: Bundle.main.bundleIdentifier ?? "unconfigured",
        environment: Bundle.main.object(forInfoDictionaryKey: "LorisReportsAPNsEnvironment") as? String ?? "unconfigured") {
        NSApplication.shared.registerForRemoteNotifications()
    }
    private static var recordedLaunch = false

    static func configuration(bundle: Bundle, directory: URL? = nil) -> FeedbackConfiguration {
        let server = bundle.object(forInfoDictionaryKey: "LorisReportsBackendAllowed") as? Bool ?? false
        let native = bundle.object(forInfoDictionaryKey: "LorisReportsMessagingVerified") as? Bool ?? false
        return FeedbackConfiguration(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("LorisReports/lumen_bridge", isDirectory: true),
            serverAuthorizationApproved: server, nativeQualificationApproved: native,
            features: server && native ? .forBuild(bundle) : .disabled, requiresExactAppAuthorization: true)
    }
    static func recordLaunch() {
        guard !recordedLaunch else { return }
        recordedLaunch = true
        review.recordLaunch()
        Task { try? await client.journal.record(.init(correlationID: UUID(), component: .ui, operation: .launch, outcome: .success)) }
    }
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .main)
    }
    static func canPresentRoute(onboarding: Bool, modal: Bool, sheet: Bool) -> Bool {
        !onboarding && !modal && !sheet
    }
}

struct BridgeHelpView: View {
    let state: BridgeState?
    @Environment(\.openURL) private var openURL
    @State private var showingMessages = false
    var body: some View {
        NavigationStack {
            List {
                Section(BridgeSupport.text("Connection help")) {
                    Text(BridgeSupport.text("Check the Frigate MQTT broker address and port in Settings."))
                    Text(BridgeSupport.text("Check your iCloud account when events are not forwarded."))
                    Text(BridgeSupport.text("HomeKit pairing is configured in the Sensors and Cameras sections."))
                }
                Section(BridgeSupport.text("Contact the team")) {
                    if BridgeSupport.configuration.deliveryEnabled {
                        Button(BridgeSupport.text("Messages")) { showingMessages = true }
                            .accessibilityIdentifier("bridge-support-messages")
                    } else {
                        NavigationLink(BridgeSupport.text("Report a Bug")) {
                            BugReportView(provider: LumenBridgeBugReportContext(state: state))
                        }
                    }
                    Text(BridgeSupport.text("Do not include passwords, camera images, broker addresses or pairing codes in your message."))
                        .font(.footnote)
                    Text(BridgeSupport.text("Replies appear here. Optional technical diagnostics require your review and confirmation."))
                        .font(.footnote)
                }
                Section(BridgeSupport.text("More from LorisLabs")) {
                    LorisLabsAppsLink(currentBundleIdentifier: "com.lorislabapp.lumenbridge")
                }
            }
            .navigationTitle(BridgeSupport.text("Help and ideas"))
            .navigationDestination(isPresented: $showingMessages) {
                FeedbackCenter(profile: BridgeSupport.profile, client: BridgeSupport.client,
                    contextProvider: nil, notifications: BridgeSupport.notifications)
            }
            .onChange(of: BridgeSupport.notifications.route, initial: true) { _, route in
                if route != nil && BridgeSupport.configuration.deliveryEnabled { showingMessages = true }
            }
            .task {
                try? await BridgeSupport.client.journal.record(.init(correlationID: UUID(), component: .ui,
                    operation: .render, outcome: .success))
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 600)
    }
}

/// Notification taps use their own window and wait for onboarding or modal work to finish.
@MainActor
final class BridgeSupportWindow {
    static let shared = BridgeSupportWindow()
    private var window: NSWindow?
    private var routeTask: Task<Void, Never>?
    var isVisible: Bool { window?.isVisible == true }

    func show(state: BridgeState? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let controller = NSHostingController(rootView: BridgeHelpView(state: state))
            let window = NSWindow(contentViewController: controller)
            window.title = BridgeSupport.text("Help and ideas")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 600))
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func presentPendingRoute() {
        routeTask?.cancel()
        routeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, BridgeSupport.configuration.deliveryEnabled,
                  BridgeSupport.client.features.notifications, BridgeSupport.notifications.route != nil {
                if BridgeSupport.canPresentRoute(onboarding: !UserDefaults.standard.bool(forKey: OnboardingView.completedKey) || OnboardingWindowPresenter.shared.isVisible,
                    modal: NSApp.modalWindow != nil, sheet: NSApp.windows.contains { $0.attachedSheet != nil }) {
                    self?.show()
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

@MainActor
final class BridgeSupportAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var onShutdown: (@MainActor () async -> Void)?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onShutdown else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await onShutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BridgeSupport.client.features.notifications else { return }
        // The current host has no other delegate. Preserve a future business owner if added.
        guard UNUserNotificationCenter.current().delegate == nil else { return }
        UNUserNotificationCenter.current().delegate = self
        Task { await BridgeSupport.notifications.resume() }
    }
    /// Opening the app again (Finder, Spotlight, `open`) shows the main
    /// window: a menu-bar app has no Dock icon to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowOpener.shared.open?() }
        return true
    }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { await BridgeSupport.notifications.didRegister(deviceToken: token) }
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        BridgeSupport.notifications.didFailRegistration()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let route = response.notification.request.content.userInfo["loris_support_route"] as? String else { return }
        await MainActor.run {
            if BridgeSupport.notifications.handleNotification(userInfo: ["loris_support_route": route]) {
                BridgeSupportWindow.shared.presentPendingRoute()
            }
        }
    }
}

/// The idle status pane offers a review opportunity after prior meaningful completions.
struct BridgeReviewOpportunity: ViewModifier {
    let interactionInProgress: Bool
    func body(content: Content) -> some View {
        content.reviewPromptWhenIdle(BridgeSupport.review,
            isIdle: !interactionInProgress, additionalEligibility: { NSApp.modalWindow == nil
                && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
                && !OnboardingWindowPresenter.shared.isVisible && !BridgeSupportWindow.shared.isVisible })
    }
}


/// User-controlled availability. Never changes system-wide power settings or prevents display sleep.
@MainActor
@Observable
final class HubAvailabilityController {
    static let shared = HubAvailabilityController()
    private var assertion: IOPMAssertionID = 0
    private var monitor: Task<Void, Never>?
    private(set) var loginEnabled = false
    private(set) var message = ""
    var keepAvailableOnPower = UserDefaults.standard.bool(forKey: "lumenhub.keepAvailableOnPower") {
        didSet { UserDefaults.standard.set(keepAvailableOnPower, forKey: "lumenhub.keepAvailableOnPower"); updatePowerAssertion() }
    }
    func start() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        updatePowerAssertion()
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.updatePowerAssertion()
            }
        }
    }
    func stop() {
        monitor?.cancel(); monitor = nil
        releaseAssertion()
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            message = loginEnabled == enabled ? "" : String(localized: "Approve \(MainWindow.appName) in System Settings > Login Items.")
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            message = String(localized: "The login setting could not be changed. Check System Settings > Login Items.")
        }
    }
    static func shouldPreventIdleSleep(enabled: Bool, onACPower: Bool) -> Bool { enabled && onACPower }
    private func updatePowerAssertion() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { releaseAssertion(); return }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        guard Self.shouldPreventIdleSleep(enabled: keepAvailableOnPower, onACPower: type == (kIOPSACPowerValue as String)) else {
            releaseAssertion(); return
        }
        guard assertion == 0 else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Lumen Hub availability on external power" as CFString, &assertion)
        if result != kIOReturnSuccess {
            assertion = 0
            message = String(localized: "macOS could not keep the Hub available. Check the Mac's sleep settings.")
        }
    }
    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}

struct HubAvailabilitySettings: View {
    private let availability = HubAvailabilityController.shared
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Launch \(MainWindow.appName) at login"), isOn: Binding(get: { availability.loginEnabled }, set: { availability.setLoginEnabled($0) }))
                Toggle("Keep the Hub available on external power", isOn: Binding(get: { availability.keepAvailableOnPower }, set: { availability.keepAvailableOnPower = $0 }))
                Text("The display may sleep. Closing the lid or choosing Sleep can still interrupt notifications and Home accessories.")
                    .font(.caption).foregroundStyle(.secondary)
                if !availability.message.isEmpty { Text(availability.message).font(.caption).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
