#if LUMEN_HUB
import LumenAssistant
import LumenHearing
import SwiftUI

/// "Assistant" pane — hands-free voice control from indoor camera microphones.
struct AssistantView: View {
    @Bindable var service: AssistantService
    @Bindable var hearing: HearingService
    @State private var token = ""
    @State private var newRoom = ""
    @State private var haURL = ""
    @State private var llmURL = ""

    var body: some View {
        Form {
            HubProBanner(status: HubProStatus.shared)
            mainSection
            camerasSection
            homeAssistantSection
            devicesSection
            LookSection(look: LookService.shared, devices: service.registry.devices)
            roomsSection
            modelSection
            safetySection
            if !service.proposals.isEmpty { proposalsSection }
            auditSection
        }
        .formStyle(.grouped)
        .task {
            service.start()
            haURL = service.settings.homeAssistantURL
            llmURL = service.settings.llmURL
            await hearing.refreshCameras()
            await service.refreshAudit()
        }
    }

    // MARK: Main

    private var mainSection: some View {
        Section {
            Toggle(AL("Voice assistant"), isOn: binding(\.enabled))
            Picker(AL("How to talk to it"), selection: binding(\.mode)) {
                Text(AL("Say “Lumen, …” first")).tag(AssistantMode.wakePhrase)
                Text(AL("Natural (no wake word)")).tag(AssistantMode.natural)
            }
            Text(service.settings.mode == .natural
                 ? AL("Natural mode only does harmless things (lights, TV, shutters). It needs a known voice and a person seen in that room. “Lumen, …” still works for the rest.")
                 : AL("Say “Lumen” then your request, for example “Lumen, turn on the living room light”."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(AL("Preview only (nothing is sent to the house)"), isOn: binding(\.dryRun))
            Toggle(AL("Notify the paired iPhones of what was done"), isOn: binding(\.notifyPhone))
            Toggle(AL("Answer out loud on this Mac"), isOn: binding(\.speakReplies))
            if service.proBlocked {
                Text(AL("Lumen Pro is needed to turn this on.")).foregroundStyle(.orange)
            }
            if let last = service.lastResult {
                LabeledContent(AL("Last result"), value: last)
            }
            if service.canUndo {
                Button(AL("Undo last action")) { Task { await service.undoLast() } }
            }
        } header: {
            Text(AL("Assistant"))
        } footer: {
            Text(AL("Lumen AI assistant. Everything runs on this Mac. Only accepted commands are written to the log below; nothing else heard is kept."))
        }
    }

    // MARK: Cameras

    private var camerasSection: some View {
        Section {
            if hearing.cameras.isEmpty {
                Text(AL("No camera yet. Check the Frigate connection.")).foregroundStyle(.secondary)
            }
            ForEach(hearing.cameras, id: \.self) { camera in
                let eligible = service.eligibility(camera: camera) == .allowed
                HStack {
                    Toggle(isOn: Binding(
                        get: { service.settings.cameras.contains(camera) },
                        set: { on in service.update { if on { $0.cameras.insert(camera) } else { $0.cameras.remove(camera) } } })) {
                        VStack(alignment: .leading) {
                            Text(pretty(camera))
                            Text(eligible ? (service.listening[camera] ?? AL("Off"))
                                          : AL("Turn it on in Transcription first (indoor, with consent)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!eligible && !service.settings.cameras.contains(camera))
                }
            }
        } header: {
            Text(AL("Microphones"))
        } footer: {
            Text(AL("Only indoor cameras with consent in Transcription can listen. Outdoor and doorbell cameras never give orders. Staff mode pauses everything."))
        }
    }

    // MARK: Home Assistant

    private var homeAssistantSection: some View {
        Section {
            TextField(AL("Address"), text: $haURL, prompt: Text(verbatim: "http://homeassistant.local:8123"))
                .onSubmit { service.update { $0.homeAssistantURL = haURL } }
            HStack {
                SecureField(service.hasToken ? AL("Token saved in the Keychain") : AL("Long-lived access token"), text: $token)
                Button(AL("Save")) {
                    let value = token
                    token = ""
                    Task { await service.saveToken(value) }
                }
                .disabled(token.isEmpty)
                if service.hasToken {
                    Button(AL("Remove"), role: .destructive) { Task { await service.removeToken() } }
                }
            }
            HStack {
                Button(AL("Test")) {
                    service.update { $0.homeAssistantURL = haURL }
                    Task { await service.testHomeAssistant() }
                }
                Button(AL("Get devices")) { Task { await service.syncDevices() } }
                Spacer()
                connectionLabel(service.homeAssistant)
            }
        } header: {
            Text(AL("Home Assistant"))
        } footer: {
            Text(AL("Create the token in Home Assistant › Profile › Security. A user without admin rights is safer; rooms then need to be set here."))
        }
    }

    private func connectionLabel(_ c: AssistantService.Connection) -> some View {
        Group {
            switch c {
            case .unknown: Text(AL("Not checked")).foregroundStyle(.secondary)
            case .checking: ProgressView().controlSize(.small)
            case .ok(let n): Label(n > 0 ? "\(n) " + AL("entities") : AL("Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    // MARK: Devices and rooms

    private var devicesSection: some View {
        Section {
            if service.registry.devices.isEmpty {
                Text(AL("Press “Get devices” to list what Home Assistant has.")).foregroundStyle(.secondary)
            }
            ForEach(service.registry.devices) { device in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(device.entityID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    tierBadge(device.kind.tier)
                    Picker(AL("Room of") + " " + device.name,
                           selection: Binding(get: { device.room ?? "" },
                                              set: { service.setRoom(device.entityID, $0.isEmpty ? nil : $0) })) {
                        Text(AL("No room")).tag("")
                        ForEach(service.registry.rooms) { room in Text(room.name).tag(room.name) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Toggle(device.name, isOn: Binding(get: { device.exposed }, set: { service.setExposed(device.entityID, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityHint(AL("Lets the assistant use this device"))
                }
            }
        } header: {
            Text(AL("Devices the assistant may use"))
        } footer: {
            Text(AL("New devices are off until you allow them."))
        }
    }

    private var roomsSection: some View {
        Section {
            ForEach(service.registry.rooms) { room in
                VStack(alignment: .leading) {
                    Text(room.name).font(.headline)
                    HStack {
                        Text(AL("Heard by:")).font(.caption).foregroundStyle(.secondary)
                        ForEach(hearing.cameras, id: \.self) { camera in
                            Toggle(pretty(camera), isOn: Binding(get: { room.cameras.contains(camera) },
                                                         set: { _ in service.toggleCamera(camera, room: room.name) }))
                                .toggleStyle(.button).controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                TextField(AL("New room"), text: $newRoom)
                Button(AL("Add")) { service.addRoom(newRoom); newRoom = "" }.disabled(newRoom.isEmpty)
            }
        } header: {
            Text(AL("Rooms"))
        } footer: {
            Text(AL("When nobody names a room, the room of the camera that heard it is used."))
        }
    }

    // MARK: Local model

    private var modelSection: some View {
        Section {
            Toggle(AL("Use the local AI model for unusual phrasing"), isOn: binding(\.llmEnabled))
            TextField(AL("llama-server address"), text: $llmURL)
                .onSubmit { service.update { $0.llmURL = llmURL } }
            HStack {
                Button(AL("Test")) {
                    service.update { $0.llmURL = llmURL }
                    Task { await service.testLLM() }
                }
                Spacer()
                connectionLabel(service.llm)
            }
        } header: {
            Text(AL("Understanding"))
        } footer: {
            Text(AL("Simple French and English requests are understood by rules, instantly. The model is asked only when rules are unsure, and it can only pick from the devices you allowed."))
        }
    }

    // MARK: Safety

    private var safetySection: some View {
        Section(AL("Safety")) {
            safetyRow("T0", AL("Lights, TV, music, shutters, plugs: done right away, for anyone."))
            safetyRow("T1", AL("Heating, camera privacy: only for a recognised adult voice."))
            safetyRow("T2", AL("Locks, alarm, garage: never done from a camera. You get a request to confirm with Face ID on your iPhone."))
            Text(AL("Children's voices: T0 only. A voice can only lower rights, never raise them. Say “no, cancel” within 10 seconds to undo."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func safetyRow(_ tier: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: tier).font(.caption.bold().monospaced()).frame(width: 28)
            Text(text)
        }
    }

    private func tierBadge(_ tier: ActionTier) -> some View {
        Text(verbatim: "T\(tier.rawValue)")
            .font(.caption2.bold().monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tier == .t2 ? Color.red.opacity(0.2) : (tier == .t1 ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)),
                        in: Capsule())
            .accessibilityLabel(AL("Safety tier") + " \(tier.rawValue)")
    }

    // MARK: Proposals and log

    private var proposalsSection: some View {
        Section(AL("Waiting for iPhone confirmation")) {
            ForEach(service.proposals) { p in
                HStack {
                    Label(actionVerb(p.plan.action) + " · " + p.plan.targets.map(\.name).joined(separator: ", "),
                          systemImage: "faceid")
                    Spacer()
                    Text(p.expiresAt, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel(AL("Time left"))
                    Button(AL("Dismiss")) { Task { await service.dismiss(p) } }
                }
            }
        }
    }

    private var auditSection: some View {
        Section {
            if let broken = service.auditIntegrity {
                Label(broken, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            if service.audit.isEmpty {
                Text(AL("Nothing yet.")).foregroundStyle(.secondary)
            }
            ForEach(service.audit) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(outcomeTitle(entry.outcome)).font(.caption.bold()).foregroundStyle(outcomeColor(entry.outcome))
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Text(pretty(entry.camera)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let ms = entry.latencyMs { Text(verbatim: "\(ms) ms").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    Text(entry.command.map { String(format: AL("“%@”"), $0) } ?? entryTargets(entry))
                    if let reason = reasonText(entry) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button(AL("Check the log")) { Task { await service.refreshAudit() } }
                Spacer()
                Button(AL("Delete the log"), role: .destructive) { Task { await service.deleteLog() } }
            }
        } header: {
            Text(AL("What the assistant did"))
        } footer: {
            Text(AL("Each line is chained to the one before it, so an edit made outside Lumen Hub shows up."))
        }
    }

    // MARK: Words


    private func pretty(_ camera: String) -> String { camera.replacingOccurrences(of: "_", with: " ").capitalized }

    private func actionVerb(_ a: DeviceAction) -> String {
        switch a {
        case .turnOn: AL("Turn on")
        case .turnOff: AL("Turn off")
        case .open: AL("Open")
        case .close: AL("Close")
        case .stop: AL("Stop")
        case .raise: AL("Raise")
        case .lower: AL("Lower")
        case .setTemperature: AL("Set temperature")
        case .lock: AL("Lock")
        case .unlock: AL("Unlock")
        case .arm: AL("Arm")
        case .disarm: AL("Disarm")
        case .query: AL("Check")
        }
    }

    private func outcomeTitle(_ o: AuditEntry.Outcome) -> String {
        switch o {
        case .executed: AL("Done")
        case .previewed: AL("Preview")
        case .answered: AL("Answered")
        case .proposed: AL("Sent to iPhone")
        case .refused: AL("Refused")
        case .failed: AL("Failed")
        case .undone: AL("Undone")
        case .confirmed: AL("Confirmed on iPhone")
        }
    }

    private func outcomeColor(_ o: AuditEntry.Outcome) -> Color {
        switch o {
        case .refused, .failed: .orange
        case .proposed: .red
        default: .primary
        }
    }

    /// Device names for a refusal (its words are never kept).
    private func entryTargets(_ e: AuditEntry) -> String {
        e.targets.map { id in service.registry.device(id: id)?.name ?? id }.joined(separator: ", ")
    }

    /// Plain words for a reason; ids and Home Assistant service names stay out of the list.
    private func reasonText(_ e: AuditEntry) -> String? {
        guard let raw = e.reason else { return nil }
        if let r = RefusalReason(rawValue: raw) {
            return switch r {
            case .tierTooHigh: AL("Not allowed from a camera.")
            case .childProfile: AL("Children's voices can only use lights, TV, music and shutters.")
            case .unknownVoiceForT1: AL("Needs a recognised adult voice.")
            case .t2NeedsKnownAdult: AL("Locks, alarm and garage need a recognised adult voice.")
            case .naturalModeT0Only: AL("Natural mode only does harmless things.")
            case .naturalModeNeedsKnownVoice: AL("Natural mode needs a known voice.")
            case .naturalModeNeedsPerson: AL("Natural mode needs a person seen in the room.")
            case .mediaPlaying: AL("Sounded like the TV or music.")
            case .notAddressed: AL("Not said to the assistant.")
            case .rateLimited: AL("Too many requests in a row.")
            case .duplicate: AL("Same request twice.")
            }
        }
        if raw == "would propose (T2)" { return AL("Preview only: no iPhone request was sent.") }
        if raw == "camera contradicted; retried once" { return AL("Sent again: the camera did not see the change.") }
        if e.outcome == .executed || e.outcome == .previewed || e.outcome == .proposed || e.outcome == .confirmed
            || UUID(uuidString: raw) != nil { return nil }
        return raw
    }

    private func binding<T>(_ key: WritableKeyPath<AssistantSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: key] }, set: { value in service.update { $0[keyPath: key] = value } })
    }
}
#endif
