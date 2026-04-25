import SwiftUI

/// First-launch onboarding wizard. Walks the user through:
///   1. Welcome — explain what the Bridge does and the privacy story.
///   2. Connect to Frigate — pick a Bonjour-discovered instance OR enter
///      host/port/credentials manually. Live test before proceeding.
///   3. iCloud — surface the CloudKit account status and explain that
///      events stay in the user's private iCloud DB end-to-end.
///   4. Done — confirmation + a "Send test event" button so the user can
///      verify the pipeline reached their iPhone before exiting.
///
/// On completion we set `lumenbridge.onboarding.completed_v1 = true` in
/// UserDefaults so the wizard never reappears unless the user resets it
/// from the Settings window.
struct OnboardingView: View {
    @Bindable var state: BridgeState
    var onApplyManualConfig: (@MainActor (_ host: String, _ port: Int, _ user: String?, _ pass: String?) async -> Void)? = nil
    var onSendTestEvent: (@MainActor () async -> Void)? = nil
    var onFinish: (@MainActor () -> Void)? = nil

    @State private var step: Step = .welcome
    @State private var manualHost: String = ""
    @State private var manualPort: String = "1883"
    @State private var manualUser: String = ""
    @State private var manualPass: String = ""
    @State private var isTestingConnection: Bool = false
    @State private var didSendTestEvent: Bool = false

    enum Step: Int, CaseIterable {
        case welcome, frigate, iCloud, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .frigate: return "Connect to Frigate"
            case .iCloud:  return "iCloud"
            case .done:    return "All set"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 640, height: 540)
    }

    // MARK: - Header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text(step.title)
                .font(.title2.weight(.semibold))
        }
    }

    // MARK: - Content per step

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .frigate: frigateStep
        case .iCloud:  iCloudStep
        case .done:    doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Frigate, the Apple-native way.")
                        .font(.title.weight(.bold))
                    Text("Lumen Bridge connects your Frigate NVR directly to Apple's ecosystem — push notifications, HomeKit cameras, iCloud clip storage — without any third-party server in between.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                bullet("lock.shield.fill", "End-to-end private",
                       "Detection events live in your own iCloud database. Apple cannot read them, neither can we.")
                bullet("bolt.heart.fill", "No third-party relay",
                       "Frigate → your Mac → CloudKit → your iPhone. Zero external services, zero rate limits, zero monthly cost.")
                bullet("infinity", "Works with what you have",
                       "Any Frigate install, any MQTT broker, any number of cameras. We meet your setup where it is.")
            }

            Spacer(minLength: 0)
        }
    }

    private var frigateStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where is your Frigate MQTT broker running?")
                .font(.headline)
            Text("Frigate publishes detection events to an MQTT broker (usually Mosquitto). The Bridge subscribes to those events and forwards them to your iCloud account.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !state.discoveredInstances.isEmpty {
                Text("Discovered on your network")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(state.discoveredInstances) { inst in
                    Button {
                        manualHost = inst.host
                        manualPort = String(inst.port)
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            VStack(alignment: .leading) {
                                Text(inst.netServiceName).font(.body)
                                Text("\(inst.host):\(inst.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 8)
            }

            Group {
                Text("Or enter it manually")
                    .font(.subheadline.weight(.semibold))
                Form {
                    TextField("Host", text: $manualHost, prompt: Text("frigate.local or 192.168.3.160"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField("Port", text: $manualPort, prompt: Text("1883"))
                        .frame(maxWidth: 100)
                    TextField("Username (optional)", text: $manualUser)
                        .autocorrectionDisabled()
                    SecureField("Password (optional)", text: $manualPass)
                }
                .formStyle(.grouped)
                .frame(maxHeight: 180)
            }

            if state.mqttConnected {
                Label("Connected to \(state.frigateHost ?? "?"):\(state.frigatePort ?? 0)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else if let err = state.lastMQTTError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private var iCloudStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: state.cloudKitStatus.isHealthy ? "icloud.fill" : "icloud.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(state.cloudKitStatus.isHealthy ? .blue : .orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.cloudKitStatus.humanReadable)
                        .font(.title2.weight(.semibold))
                    Text("Detection events are stored in your private iCloud database, scoped to the `iCloud.com.lorislabapp.lumenbridge` container. Only your Apple ID can read them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                bullet("lock.icloud.fill", "Private database",
                       "Records sit in your private CloudKit DB. Apple's servers carry the encrypted data; only your devices have the key.")
                bullet("bolt.fill", "Silent push delivery",
                       "When Bridge writes an event, CloudKit fires a silent push to all your Apple devices in <2s. Lumen iOS unwraps it and shows the notification.")
                bullet("dollarsign.circle", "No additional cost",
                       "Uses your existing iCloud free tier (5GB shared, but FrigateEvent records are tiny — millions per year fit easily).")
            }

            Spacer(minLength: 0)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            Text("You're set up.")
                .font(.title.weight(.bold))
            Text("The Bridge is running in your menu bar. As Frigate detects events, you'll get notifications on your iPhone, iPad, Mac, and Watch — no server in between.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            VStack(spacing: 8) {
                metric(label: "MQTT", value: state.mqttConnected ? "Connected" : "—",
                       color: state.mqttConnected ? .green : .secondary)
                metric(label: "iCloud", value: state.cloudKitStatus.humanReadable,
                       color: state.cloudKitStatus.isHealthy ? .green : .orange)
                metric(label: "Events received", value: "\(state.eventsReceived)", color: .secondary)
                metric(label: "Events forwarded to iCloud", value: "\(state.eventsForwarded)", color: .secondary)
            }
            .padding(.top, 8)

            Button {
                Task {
                    await onSendTestEvent?()
                    didSendTestEvent = true
                }
            } label: {
                Label(didSendTestEvent ? "Test event sent" : "Send test event",
                      systemImage: didSendTestEvent ? "checkmark.circle.fill" : "paperplane")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.bordered)
            .disabled(didSendTestEvent || !state.cloudKitStatus.isHealthy)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step.rawValue > 0 {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            primaryButton
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Continue") { step = .frigate }
                .buttonStyle(.borderedProminent)

        case .frigate:
            Button {
                Task { await testAndAdvance() }
            } label: {
                if isTestingConnection {
                    ProgressView().controlSize(.small)
                } else {
                    Text(state.mqttConnected ? "Continue" : "Test & Continue")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTestingConnection || (manualHost.trimmingCharacters(in: .whitespaces).isEmpty && !state.mqttConnected))

        case .iCloud:
            Button("Continue") { step = .done }
                .buttonStyle(.borderedProminent)
                .disabled(!state.cloudKitStatus.isHealthy)

        case .done:
            Button("Finish") {
                UserDefaults.standard.set(true, forKey: Self.completedKey)
                onFinish?()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func testAndAdvance() async {
        // If already connected (from saved config or prior step), just advance.
        if state.mqttConnected {
            step = .iCloud
            return
        }
        guard let port = Int(manualPort), port > 0, port <= 65535 else {
            state.lastMQTTError = "Port must be between 1 and 65535"
            return
        }
        isTestingConnection = true
        defer { isTestingConnection = false }
        await onApplyManualConfig?(manualHost,
                                    port,
                                    manualUser.isEmpty ? nil : manualUser,
                                    manualPass.isEmpty ? nil : manualPass)
        // Give it a beat for the connection callback to land.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if state.mqttConnected {
            step = .iCloud
        }
    }

    // MARK: - Helpers

    private func bullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .frame(maxWidth: 360)
    }

    /// Persisted onboarding completion flag. Versioned so we can re-trigger
    /// onboarding for users who already finished a v1 wizard if/when v2
    /// adds significantly different steps (HomeKit pairing, etc).
    static let completedKey = "lumenbridge.onboarding.completed_v1"
}
