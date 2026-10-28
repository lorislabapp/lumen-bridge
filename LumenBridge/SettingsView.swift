import SwiftUI

/// Frigate / MQTT connection form, shown in the main window's "Frigate"
/// pane. Connection only: HomeKit and zone alerts have their own panes
/// (their toggles used to be duplicated here without being wired).
///
/// Saving applies immediately: the coordinator reconnects MQTT with the
/// new credentials (password in the Keychain, never in UserDefaults).
struct SettingsView: View {
    @Bindable var state: BridgeState
    /// Called when the user taps "Save & Connect". The coordinator owns the
    /// actual reconnect / persistence logic.
    var onApply: (@MainActor (_ host: String, _ port: Int, _ username: String?, _ password: String?) async -> Void)? = nil
    /// Turns encrypted MQTT on/off (the coordinator reconnects).
    var onSetTLS: (@MainActor (Bool) async -> Void)? = nil

    @State private var host: String = ""
    @State private var portText: String = "1883"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isApplying: Bool = false

    var body: some View {
        Form {
            Section {
                TextField("Host", text: $host, prompt: Text("frigate.local or 10.9.8.42"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                TextField("Port", text: $portText, prompt: Text("1883"))
                Toggle("Encrypted connection (TLS)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: BridgeCoordinator.mqttUseTLSKey) },
                    set: { enabled in
                        if enabled && portText == "1883" { portText = "8883" }
                        if !enabled && portText == "8883" { portText = "1883" }
                        Task { await onSetTLS?(enabled) }
                    }))
                if state.mqttConnected && !state.mqttEncrypted {
                    Label("Not encrypted: your MQTT password and events cross the network in clear text. Turn on TLS if your broker supports it.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Frigate MQTT broker")
            } footer: {
                Text("Find this under Frigate → Settings → MQTT. Defaults to port 1883 (no TLS).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Username (optional)", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password (optional)", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Authentication")
            } footer: {
                Text("Leave blank if your Mosquitto / EMQX broker allows anonymous connections (Frigate's default).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                HStack {
                    Spacer()
                    Button {
                        Task { await apply() }
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save & Connect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Status")
            }

            Section {
                if !state.discoveredInstances.isEmpty {
                    ForEach(state.discoveredInstances) { instance in
                        Button {
                            host = instance.host
                            portText = String(instance.port)
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                VStack(alignment: .leading) {
                                    Text(instance.netServiceName)
                                        .font(.subheadline)
                                    Text(verbatim: "\(instance.host):\(String(instance.port))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Use")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("No instances discovered via Bonjour yet. If your Frigate is on a different VLAN or doesn't advertise `_frigate._tcp`, just enter the host above manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Discovered (Bonjour)")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Pre-fill from the current config if present.
            if let h = state.frigateHost { host = h }
            if let p = state.frigatePort { portText = String(p) }
            if let u = state.mqttUsername { username = u }
            if let pw = state.mqttPassword { password = pw }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.mqttConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            if state.mqttConnected, let h = state.frigateHost, let p = state.frigatePort {
                Text("Connected to \(h):\(String(p))")
                    .font(.callout)
            } else if let err = state.lastMQTTError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("Not connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func apply() async {
        guard let port = Int(portText), port > 0, port <= 65535 else {
            state.lastMQTTError = String(localized: "Port must be a number between 1 and 65535")
            return
        }
        isApplying = true
        defer { isApplying = false }
        let user = username.isEmpty ? nil : username
        let pass = password.isEmpty ? nil : password
        await onApply?(host, port, user, pass)
    }
}
