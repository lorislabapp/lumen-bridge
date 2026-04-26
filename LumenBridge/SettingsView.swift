import SwiftUI

/// Manual Frigate / MQTT configuration form. Opens in a Settings window
/// (Window scene under macOS) when the user taps "Settings…" in the menu-
/// bar popover, or automatically on first launch when no host has been
/// configured and Bonjour has not surfaced anything yet.
///
/// Saving applies immediately: the coordinator reconnects MQTT with the
/// new credentials. The host/port/credentials persist across launches
/// via UserDefaults (managed by the coordinator).
struct SettingsView: View {
    @Bindable var state: BridgeState
    /// Called when the user taps "Save & Connect". The coordinator owns the
    /// actual reconnect / persistence logic.
    var onApply: (@MainActor (_ host: String, _ port: Int, _ username: String?, _ password: String?) async -> Void)? = nil
    /// Called when the user toggles the HomeKit bridge in Settings. The
    /// coordinator owns the server start/stop + flag persistence so a
    /// runtime toggle takes effect immediately (no app relaunch).
    var onToggleHAP: (@MainActor (_ enabled: Bool) async -> Void)? = nil
    /// Called when the user toggles the Homebridge camera sidecar.
    var onToggleHomebridge: (@MainActor (_ enabled: Bool) async -> Void)? = nil

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
                    .frame(maxWidth: 100)
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
            } header: {
                Text("Status")
            }

            Section {
                Toggle("Enable HomeKit bridge", isOn: hapEnabledBinding)
                    .help("Exposes each Frigate camera as a HomeKit motion sensor in the Apple Home app. Requires re-pairing if you change your iCloud account.")
                switch state.hapStatus {
                case .stopped:
                    Text("HomeKit bridge is off. Toggle on to start pairing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running(let setupCode, _, let count):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing code")
                            .font(.caption.weight(.semibold))
                        Text(setupCode)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                        Text("Open Apple Home → Add Accessory → More options → enter this code. \(count) Frigate camera\(count == 1 ? "" : "s") exposed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .error(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("HomeKit motion sensors (beta)")
            } footer: {
                Text("Native Swift HAP server. Each Frigate camera shows up as a motion sensor in Apple Home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Frigate web URL", text: frigateWebURLBinding,
                          prompt: Text("https://frigate.local:5000"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()

                Toggle("Enable HomeKit cameras", isOn: homebridgeEnabledBinding)
                    .help("Spawns a private Homebridge process that exposes each Frigate go2rtc stream as a HomeKit camera. Live view in Apple Home, audio off by default.")

                switch state.homebridgeStatus {
                case .stopped:
                    Text("Cameras off. Toggle on to install Homebridge and start streaming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running(let setupCode):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cameras pairing code")
                            .font(.caption.weight(.semibold))
                        Text(setupCode)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                        Text("Open Apple Home → Add Accessory → enter this code. The cameras bridge appears as ‘Lumen Bridge Cameras’ — separate from the motion-sensor bridge above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .error(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("HomeKit cameras (alpha)")
            } footer: {
                Text("Phase 5 v0.2 — uses a bundled Homebridge sidecar with homebridge-camera-ffmpeg. RTSP streams come from Frigate's go2rtc on port 8554. First-run install ~30-90s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                    Text("\(instance.host):\(instance.port)")
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
        .padding()
        .frame(width: 460, height: 540)
        .navigationTitle("Lumen Bridge — Frigate Connection")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await apply() }
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save & Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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
                Text("Connected to \(h):\(p)")
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

    /// Bind to the user-supplied Frigate web URL — used by the Homebridge
    /// sidecar to fetch cameras list and RTSP host. Stored under the same
    /// UserDefaults bundle as the rest of the Bridge config.
    private var frigateWebURLBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "lumenbridge.homebridge.frigate_web_url") ?? "" },
            set: { UserDefaults.standard.set($0, forKey: "lumenbridge.homebridge.frigate_web_url") }
        )
    }

    /// Two-way binding for the Homebridge sidecar toggle. Routes through
    /// the coordinator (same pattern as `hapEnabledBinding`) so the
    /// process spawns/quits immediately on flip.
    private var homebridgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "lumenbridge.homebridge.cameras_enabled") },
            set: { newValue in
                Task { @MainActor in
                    if let onToggleHomebridge {
                        await onToggleHomebridge(newValue)
                    } else {
                        UserDefaults.standard.set(newValue, forKey: "lumenbridge.homebridge.cameras_enabled")
                    }
                }
            }
        )
    }

    /// Two-way binding to the persisted HAP-enabled flag. Reading hits
    /// UserDefaults; writing routes through the coordinator so the HAP
    /// server starts or stops immediately — no relaunch needed.
    private var hapEnabledBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "lumenbridge.hap.enabled") },
            set: { newValue in
                Task { @MainActor in
                    if let onToggleHAP {
                        await onToggleHAP(newValue)
                    } else {
                        // Fallback: at least persist the flag so the next
                        // launch picks it up.
                        UserDefaults.standard.set(newValue, forKey: "lumenbridge.hap.enabled")
                    }
                }
            }
        )
    }

    private func apply() async {
        guard let port = Int(portText), port > 0, port <= 65535 else {
            state.lastMQTTError = "Port must be a number between 1 and 65535"
            return
        }
        isApplying = true
        defer { isApplying = false }
        let user = username.isEmpty ? nil : username
        let pass = password.isEmpty ? nil : password
        await onApply?(host, port, user, pass)
    }
}
