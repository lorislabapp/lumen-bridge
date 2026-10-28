import AppKit
import SwiftUI

/// Guided setup shares the connection and alert editors with advanced settings.
/// HomeKit and alerts stay opt-in; iCloud availability is not delivery proof.
struct OnboardingView: View {
    @Bindable var state: BridgeState
    var coordinator: BridgeCoordinator?
    var onFinish: (@MainActor () -> Void)? = nil

    @State private var step: Step = .frigate
    @State private var isWorking = false
    @State private var testResult: Bool?

    init(state: BridgeState, coordinator: BridgeCoordinator?, initialStep: Step = .frigate,
         onFinish: (@MainActor () -> Void)? = nil) {
        self.state = state
        self.coordinator = coordinator
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    enum Step: Int, CaseIterable {
        case frigate, notifications, home, alerts, ai

        var title: String {
            switch self {
            case .frigate: String(localized: "Frigate")
            case .notifications: String(localized: "Notifications")
            case .home: String(localized: "Home")
            case .alerts: String(localized: "What to watch?")
            case .ai: String(localized: "AI (optional)")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle")
                        Text(item.title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .foregroundStyle(item == step ? HubPalette.onAccent : HubPalette.ink)
                    .background(item == step ? HubPalette.accent : HubPalette.tile(item.rawValue < step.rawValue ? .ok : .later), in: Capsule())
                    .accessibilityLabel(Text("Step \(item.rawValue + 1): \(item.title)"))
                    .accessibilityValue(item == step ? String(localized: "Current step") : item.rawValue < step.rawValue ? String(localized: "Visited") : String(localized: "Not visited"))
                }
            }
            .padding(24)

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if step != .frigate {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .frigate }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step == .ai ? String(localized: "Finish") : String(localized: "Continue")) {
                    if step == .ai {
                        UserDefaults.standard.set(true, forKey: Self.completedKey)
                        onFinish?()
                    } else {
                        step = Step(rawValue: step.rawValue + 1) ?? .ai
                    }
                }
                .buttonStyle(HubActionStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .disabled(isWorking)
            .padding(24)
        }
        .background(HubPalette.panel)
        .frame(minWidth: 760, minHeight: 640)
        .onChange(of: state.cloudKitStatus) { _, _ in testResult = nil }
    }

    private var canContinue: Bool {
        switch step {
        case .frigate: state.mqttConnected
        case .notifications: state.mqttConnected && state.cloudKitStatus.isHealthy
        case .home, .alerts: true
        case .ai: state.mqttConnected && state.cloudKitStatus.isHealthy
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .frigate:
            VStack(alignment: .leading, spacing: 0) {
                heading("Where is your Frigate?", "Connect to the MQTT broker used by Frigate. Continue once the connection is established.")
                SettingsView(state: state, onApply: { host, port, user, password in
                    await coordinator?.applyManualConfig(host: host, port: port, username: user, password: password)
                }, onSetTLS: { enabled in
                    await coordinator?.setMQTTUseTLS(enabled)
                })
            }
        case .notifications:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading("Notify your Apple devices?", "Sign in to the same iCloud account on this Mac and in Lumen on your iPhone or iPad.")
                    VStack(alignment: .leading, spacing: 16) {
                        Label(state.cloudKitStatus.humanReadable,
                              systemImage: state.cloudKitStatus.isHealthy ? "checkmark.icloud" : "icloud")
                            .font(.headline)
                        Text("Events are saved in your private iCloud database. Notification delivery also depends on your device settings and Apple's background delivery.")
                            .foregroundStyle(.secondary)
                        if !state.cloudKitStatus.isHealthy {
                            Button("Open iCloud settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Check again") {
                                perform { await coordinator?.refreshCloudKitStatus() }
                            }
                            .disabled(isWorking || coordinator == nil)
                        }
                        Button("Send test event") {
                            perform { testResult = await coordinator?.sendTestEvent() ?? false }
                        }
                        .disabled(isWorking || !state.cloudKitStatus.isHealthy || coordinator == nil)
                        if isWorking { ProgressView().controlSize(.small) }
                        if let testResult {
                            Label(testResult ? String(localized: "Test saved to iCloud. Check that it appears on your other device.") : String(localized: "The test could not be saved. Check iCloud and try again."),
                                  systemImage: testResult ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(testResult ? Color.secondary : HubPalette.text(.error))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        case .home:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    #if LUMEN_HUB
                    heading("Add Frigate to Apple Home?", "Optional: expose motion sensors and zone doorbells to Apple Home. Live cameras can be configured later in advanced settings.")
                    #else
                    heading("Add Frigate to Apple Home?", "Optional: expose motion sensors and zone doorbells to Apple Home.")
                    #endif
                    VStack(alignment: .leading, spacing: 16) {
                        if state.hapStatus.isRunning {
                            if case .running(let code, _, _) = state.hapStatus {
                                Label("Home bridge is running", systemImage: "house.fill")
                                    .font(.headline)
                                Text("In Apple Home, choose Add Accessory, then More Options, and select this bridge. Enter this code when asked:")
                                Text(code).font(.title.monospaced()).textSelection(.enabled)
                                Text("Running does not confirm pairing. Check the accessories in Apple Home.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            if case .error(let message) = state.hapStatus {
                                Text(message).foregroundStyle(HubPalette.text(.error))
                            }
                            Button("Enable Apple Home") {
                                perform { await coordinator?.setHAPEnabled(true) }
                            }
                            .buttonStyle(HubActionStyle())
                            .disabled(isWorking || coordinator == nil)
                        }
                        if isWorking { ProgressView().controlSize(.small) }
                        if !state.hapStatus.isRunning {
                            Text("You can continue without enabling Apple Home.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        case .alerts:
            VStack(alignment: .leading, spacing: 0) {
                heading("Which places should we watch?", "Add a mailbox, gate or another Frigate zone. Alerts save as you edit. You can also continue and add them later.")
                ZoneAlertsView(state: state, onSave: { alerts in
                    await coordinator?.setZoneAlerts(alerts)
                })
            }
        case .ai:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading("AI on this Mac, later", "Local visit descriptions and recognition are planned. There is nothing to enable or download in this version.")
                    VStack(alignment: .leading, spacing: 16) {
                        Label(state.mqttConnected ? String(localized: "Frigate connected") : String(localized: "Frigate disconnected"),
                              systemImage: state.mqttConnected ? "checkmark.circle" : "exclamationmark.triangle")
                        Label(state.cloudKitStatus.humanReadable, systemImage: "icloud")
                        Text("You can return to guided setup from the Hub home screen at any time.")
                            .foregroundStyle(.secondary)
                        if !canContinue {
                            Text("Go back and restore the Frigate and iCloud connections before finishing.")
                                .foregroundStyle(HubPalette.text(.error))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    private func heading(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(HubPalette.ink)
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            await operation()
        }
    }

    // Preserve completion for existing installations; the assistant can be reopened.
    static let completedKey = "lumenbridge.onboarding.completed_v1"
}
