#if LUMEN_HUB
import LumenHearing
import SwiftUI

/// "Transcription" pane — off by default, per-camera opt-in with consent,
/// outdoor lock, staff mode, retention, keywords, engine and model status.
struct HearingSettingsView: View {
    @Bindable var service: HearingService
    @State private var consentCamera: ConsentRequest?
    @State private var newKeyword = ""
    @State private var confirmDelete = false

    struct ConsentRequest: Identifiable {
        let camera: String
        var id: String { camera }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Transcribe speech from cameras", isOn: binding(\.enabled))
                    .toggleStyle(.switch)
                Label("Everything stays on this Mac. Nothing goes to LorisLabs or a cloud.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = service.storeError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }

            Section {
                Toggle(isOn: binding(\.staffPresent)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Staff present")
                        Text("Nanny, cleaner or carer at home? Turn this on: all listening stops.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .disabled(!service.settings.enabled)

            camerasSection
            keywordsSection
            engineSection
            storageSection
            creditsSection
        }
        .formStyle(.grouped)
        .task {
            await service.refreshCameras()
            await service.refreshEngineStates()
        }
        .sheet(item: $consentCamera) { request in
            HearingConsentSheet(camera: request.camera,
                                suggested: service.placement(for: request.camera)
                                    ?? HearingSettings.suggestedPlacement(cameraName: request.camera)) { placement in
                try? service.grantConsent(camera: request.camera, placement: placement)
                consentCamera = nil
            } onCancel: {
                consentCamera = nil
            }
        }
    }

    // MARK: Cameras

    private var camerasSection: some View {
        Section {
            if let error = service.cameraError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Transcription uses the Frigate web address and login from the Frigate page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(service.cameras, id: \.self) { camera in
                cameraRow(camera)
            }
        } header: {
            Text("Cameras")
        } footer: {
            Text("Each camera is off until you turn it on and confirm. Outdoor and street cameras stay locked off.")
        }
        .disabled(!service.settings.enabled)
    }

    private func cameraRow(_ camera: String) -> some View {
        let policy = service.settings.cameras[camera]
        let locked = policy?.placement?.isLocked ?? false
        let on = service.settings.eligibility(camera: camera) == .allowed
            || (policy?.enabled == true && service.settings.staffPresent)
        return HStack {
            Text(camera.replacingOccurrences(of: "_", with: " ").capitalized)
            Spacer()
            Picker("Place", selection: Binding(
                get: { policy?.placement },
                set: { new in if let new { service.update { $0.setPlacement(new, camera: camera) } } })) {
                Text("Choose…").tag(CameraPlacement?.none)
                Text("Indoor").tag(CameraPlacement?.some(.indoor))
                Text("Outdoor").tag(CameraPlacement?.some(.outdoor))
                Text("Facing the street").tag(CameraPlacement?.some(.street))
            }
            .labelsHidden()
            .frame(width: 150)
            if locked {
                Label("Locked", systemImage: "lock.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help(Text("Outdoor and street cameras can never be transcribed."))
                    .accessibilityLabel(Text("Locked off: outdoor camera"))
            }
            Toggle("Transcribe", isOn: Binding(
                get: { on },
                set: { wanted in
                    if wanted {
                        if (try? service.update({ try $0.setCamera(camera, enabled: true) })) == nil {
                            consentCamera = ConsentRequest(camera: camera)
                        }
                    } else {
                        try? service.update { try $0.setCamera(camera, enabled: false) }
                    }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(locked)
        }
    }

    // MARK: Keywords

    private var keywordsSection: some View {
        Section {
            HStack {
                TextField("Add a word or phrase", text: $newKeyword)
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword)
                    .disabled(!HearingSettings.keywordLength.contains(newKeyword.trimmingCharacters(in: .whitespaces).count))
            }
            ForEach(service.settings.keywords, id: \.self) { keyword in
                HStack {
                    Text(keyword)
                    Spacer()
                    Button {
                        service.update { $0.setKeywords($0.keywords.filter { $0 != keyword }) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove \(keyword)"))
                }
            }
        } header: {
            Text("Keyword alerts")
        } footer: {
            Text("Your iPhone gets “Keyword heard” and the camera name. The words themselves never leave this Mac.")
        }
        .disabled(!service.settings.enabled)
    }

    private func addKeyword() {
        let word = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HearingSettings.keywordLength.contains(word.count) else { return }
        service.update { $0.setKeywords($0.keywords + [word]) }
        newKeyword = ""
    }

    // MARK: Engine

    private var engineSection: some View {
        Section {
            Picker("Engine", selection: binding(\.engine)) {
                Text("Automatic").tag(EnginePreference.automatic)
                Text("Parakeet (best accuracy)").tag(EnginePreference.parakeet)
                Text("Apple (built in)").tag(EnginePreference.apple)
            }
            Picker("Language", selection: binding(\.language)) {
                Text("Automatic").tag(HearingLanguage.automatic)
                Text("French").tag(HearingLanguage.french)
                Text("English").tag(HearingLanguage.english)
            }
            engineRow(title: "Parakeet v3", state: service.parakeetState,
                      action: ("Download (about 480 MB)", { await service.downloadParakeet() }))
            engineRow(title: "Apple speech", state: service.appleState,
                      action: ("Install", { await service.prepareApple() }))
            if let rtf = service.queue.lastRealTimeFactor, rtf > 0 {
                Text("Last clip: \(Int((1 / rtf).rounded()))× faster than real time")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Speech engine")
        } footer: {
            Text("One shared engine works through clips one at a time. Automatic uses Parakeet once downloaded, else Apple.")
        }
    }

    private func engineRow(title: LocalizedStringKey, state: HearingService.ModelState,
                           action: (LocalizedStringKey, () async -> Void)) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch state {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
            case .notDownloaded, .unknown:
                Button(action.0) { Task { await action.1() } }
            case .unsupported(let why):
                Text(why).font(.caption).foregroundStyle(.secondary)
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
                Button("Retry") { Task { await action.1() } }
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            Picker("Keep transcripts for", selection: binding(\.retentionDays)) {
                ForEach(HearingSettings.retentionChoices, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            HStack {
                Text("\(service.transcriptCount) transcripts on this Mac")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete all…", role: .destructive) { confirmDelete = true }
            }
            if service.queue.pending > 0 || service.queue.processing != nil {
                Text("\(service.queue.pending) clips waiting").font(.caption).foregroundStyle(.secondary)
            }
            if let note = service.lastAlertNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Older transcripts are deleted automatically.")
        }
        .confirmationDialog("Delete every transcript on this Mac?", isPresented: $confirmDelete) {
            Button("Delete all", role: .destructive) { Task { await service.deleteAllTranscripts() } }
        }
    }

    private var creditsSection: some View {
        Section("Credits") {
            Text(verbatim: "NVIDIA Parakeet TDT 0.6B v3 — CC BY 4.0 · FluidAudio — Apache 2.0 · Silero VAD — MIT")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<HearingSettings, T>) -> Binding<T> {
        Binding(get: { service.settings[keyPath: keyPath] },
                set: { value in service.update { $0[keyPath: keyPath] = value } })
    }
}

/// The explicit consent shown before a camera is transcribed for the first time.
struct HearingConsentSheet: View {
    let camera: String
    let onAccept: (CameraPlacement) -> Void
    let onCancel: () -> Void
    @State private var placement: CameraPlacement?
    @State private var informed = false

    init(camera: String, suggested: CameraPlacement?, onAccept: @escaping (CameraPlacement) -> Void,
         onCancel: @escaping () -> Void) {
        self.camera = camera
        self.onAccept = onAccept
        self.onCancel = onCancel
        _placement = State(initialValue: suggested)
    }

    private var name: String { camera.replacingOccurrences(of: "_", with: " ").capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listen to “\(name)”?").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 10) {
                point("lock.shield", "Speech becomes text on this Mac only. Nothing is sent to LorisLabs or a cloud.")
                point("exclamationmark.triangle", "In France, recording someone’s private words without consent is a crime (Code pénal, art. 226-1: up to 1 year and €45,000; 2 years and €60,000 between partners). Keeping or using the text is also an offence (art. 226-2).")
                point("person.2", "Tell everyone who lives here. Tell every visitor too, and put up a visible sign.")
                point("figure.and.child.holdinghands", "Nanny, cleaner or carer at home? Turn on “Staff present”: listening stops.")
                point("tree", "Outdoor and street cameras are always locked off.")
                point("waveform.slash", "No emotion or tone analysis. Text is deleted after the time you choose.")
            }
            Picker("This camera is", selection: $placement) {
                Text("Choose…").tag(CameraPlacement?.none)
                Text("Indoor").tag(CameraPlacement?.some(.indoor))
                Text("Outdoor").tag(CameraPlacement?.some(.outdoor))
                Text("Facing the street").tag(CameraPlacement?.some(.street))
            }
            if placement?.isLocked == true {
                Label("This camera stays locked off.", systemImage: "lock.fill").foregroundStyle(.orange)
            }
            Toggle("I have told the people who live here, and I will tell visitors.", isOn: $informed)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Turn on") { if let placement { onAccept(placement) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!informed || placement != .indoor)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
    }
}
#endif
