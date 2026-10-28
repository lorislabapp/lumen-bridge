import SwiftUI

/// "Zone alerts" pane: the owner lists the places to watch (mailbox, gate,
/// front door, driveway…). Each alert = camera + zone + who counts, its own
/// HomeKit doorbell and its own iPhone notification. Changes save at once.
struct ZoneAlertsView: View {
    @Bindable var state: BridgeState
    var onSave: (@MainActor ([ZoneAlert]) async -> Void)?

    @State private var alerts: [ZoneAlert] = []
    @State private var loaded = false

    private struct Preset: Identifiable {
        let id = UUID()
        let name: LocalizedStringResource
        let zoneHint: String
        let icon: String
    }

    private var presets: [Preset] {
        [
            Preset(name: "Mailbox", zoneHint: "mailbox", icon: "envelope"),
            Preset(name: "Gate", zoneHint: "gate", icon: "door.garage.closed"),
            Preset(name: "Front door", zoneHint: "door", icon: "door.left.hand.closed"),
            Preset(name: "Driveway", zoneHint: "driveway", icon: "car"),
        ]
    }

    var body: some View {
        Form {
            Section {
                Text("Get a notification, and a doorbell chime on your HomePods, when someone Frigate doesn't recognise passes through a zone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.mqttConnected {
                    Label("Connect to Frigate first (Frigate page): cameras and zones come from it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ForEach($alerts) { $alert in
                alertSection($alert)
            }

            Section {
                Menu {
                    ForEach(presets) { preset in
                        Button {
                            add(name: String(localized: preset.name), zoneHint: preset.zoneHint)
                        } label: {
                            Label(String(localized: preset.name), systemImage: preset.icon)
                        }
                    }
                    Divider()
                    Button(String(localized: "Other place…")) {
                        add(name: String(localized: "New alert"), zoneHint: "")
                    }
                } label: {
                    Label("Add an alert", systemImage: "plus.circle.fill")
                }
                .disabled(alerts.count >= ZoneAlertStore.maximumAlerts)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            alerts = state.zoneAlerts
        }
        .onChange(of: alerts) { _, newValue in
            let valid = newValue.filter(\.isValid)
            Task { await onSave?(valid) }
        }
    }

    // MARK: - One alert

    @ViewBuilder
    private func alertSection(_ alert: Binding<ZoneAlert>) -> some View {
        let id = alert.wrappedValue.id
        Section {
            Toggle(isOn: alert.enabled) {
                TextField("Name", text: alert.name, prompt: Text("Mailbox"))
                    .font(.headline)
            }
            picker("Camera", selection: alert.configuration.camera, options: cameraOptions(current: alert.wrappedValue.configuration.camera))
            picker("Zone", selection: alert.configuration.mailboxZone,
                   options: zoneOptions(camera: alert.wrappedValue.configuration.camera,
                                        current: alert.wrappedValue.configuration.mailboxZone))
            Picker("Who", selection: whoBinding(alert)) {
                Text("People").tag("person")
                Text("Vehicles").tag("car")
                Text("Animals").tag("dog")
            }
            Toggle("Ignore people and plates Frigate recognises", isOn: alert.configuration.ignoreRecognized)

            if let last = state.lastZoneVisits[id] {
                Text("Last visit: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let outcome = state.lastZonePushOutcome[id] {
                Text("iPhone notification: \(outcome)")
                    .font(.caption)
                    .foregroundStyle(outcome == "sent" ? Color.secondary : Color.orange)
            }
            if !alert.wrappedValue.isValid {
                Text("Choose a name, a camera and a zone to turn this alert on.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .destructive) {
                    alerts.removeAll { $0.id == id }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Menu when Frigate already sent names, text field otherwise.
    @ViewBuilder
    private func picker(_ title: LocalizedStringKey, selection: Binding<String>, options: [String]) -> some View {
        if options.isEmpty {
            TextField(title, text: selection, prompt: Text("Name in Frigate"))
                .autocorrectionDisabled()
        } else {
            Picker(title, selection: selection) {
                if selection.wrappedValue.isEmpty { Text("Choose…").tag("") }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private func cameraOptions(current: String) -> [String] {
        var all = Set(state.seenZones.keys)
        if !current.isEmpty { all.insert(current) }
        return all.sorted()
    }

    private func zoneOptions(camera: String, current: String) -> [String] {
        var all = state.seenZones[camera] ?? []
        if !current.isEmpty { all.insert(current) }
        return all.sorted()
    }

    private func whoBinding(_ alert: Binding<ZoneAlert>) -> Binding<String> {
        Binding(
            get: { alert.wrappedValue.configuration.labels.first ?? "person" },
            set: { alert.wrappedValue.configuration.labels = [$0] }
        )
    }

    private func add(name: String, zoneHint: String) {
        let camera = cameraOptions(current: "").first ?? ""
        let zones = zoneOptions(camera: camera, current: "")
        let zone = zones.first { $0.localizedCaseInsensitiveContains(zoneHint) && !zoneHint.isEmpty } ?? ""
        alerts.append(ZoneAlert(name: name,
                                configuration: .init(camera: camera, mailboxZone: zone)))
    }
}
