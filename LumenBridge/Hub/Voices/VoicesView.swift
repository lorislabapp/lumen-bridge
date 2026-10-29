#if LUMEN_HUB
import LumenHearing
import SwiftUI

/// "Voices" pane — speakers (S1, S2) by default; named voices only for people
/// who consented; unknown voices to name, merge, ignore or forget.
struct VoicesView: View {
    @Bindable var service: VoiceService
    @Bindable var hearing: HearingService
    @State private var consentFor: NewPerson?
    @State private var teach: VoiceProfile?
    @State private var forgetting: VoiceProfile?
    @State private var confirmDeleteAll = false
    /// After the consent sheet: name this unknown voice as the new person.
    @State private var pendingCluster: Int64?

    struct NewPerson: Identifiable {
        var name = ""
        var faceName = ""
        var id = UUID()
    }

    /// What opens at once (screens harness): a sheet or the "Forget" dialog.
    enum Presenting {
        case none, consent(NewPerson), teach(VoiceProfile), forget(VoiceProfile)
    }

    init(service: VoiceService, hearing: HearingService, presenting: Presenting = .none) {
        self.service = service
        self.hearing = hearing
        switch presenting {
        case .none: break
        case .consent(let p): _consentFor = State(initialValue: p)
        case .teach(let p): _teach = State(initialValue: p)
        case .forget(let p): _forgetting = State(initialValue: p)
        }
    }

    var body: some View {
        Form {
            HubProBanner(status: HubProStatus.shared)
            settingsSection
            if service.settings.identificationEnabled {
                peopleSection
                unknownSection
            }
            modelSection
            storageSection
        }
        .formStyle(.grouped)
        .task { await service.refresh(); await service.refreshModelState() }
        .sheet(item: $consentFor) { request in
            VoiceConsentSheet(initialName: request.name, initialFace: request.faceName) { name, face, child, language in
                let cluster = pendingCluster
                pendingCluster = nil
                consentFor = nil
                Task {
                    guard let profile = await service.addPerson(name: name, faceName: face, isChild: child,
                                                                consentLanguage: language) else { return }
                    if let cluster {
                        await service.name(cluster: cluster, as: profile.id)
                    } else {
                        teach = profile // next step: pick 3–5 clips
                    }
                }
            } onCancel: {
                pendingCluster = nil
                consentFor = nil
            }
        }
        .sheet(item: $teach) { profile in
            TeachVoiceSheet(service: service, profile: profile) { teach = nil }
        }
        .confirmationDialog(forgetTitle, isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) {
                if let p = forgetting { Task { await service.forget(p.id) } }
                forgetting = nil
            }
        } message: {
            Text("Deletes this person’s voice samples, name and face link, and removes the name from every transcript line.")
        }
        .confirmationDialog("Delete every voice on this Mac?", isPresented: $confirmDeleteAll) {
            Button("Delete all voices", role: .destructive) { Task { await service.deleteEverything() } }
        }
    }

    private var forgetTitle: String {
        forgetting.map { String(localized: "Forget \($0.name)?") } ?? ""
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Toggle(isOn: binding(\.diarizationEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Separate speakers")
                    Text("Transcript lines show who spoke: S1, S2… No voice is saved for this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: binding(\.identificationEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recognise named voices")
                    Text("Only people who agreed. A name is a label only: it never unlocks or allows anything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!service.settings.diarizationEnabled)
            if service.settings.identificationEnabled {
                Toggle("Group unknown voices", isOn: binding(\.rememberUnknownVoices))
                Toggle("Learn from very sure matches (adults only)", isOn: binding(\.autoLearn))
                ForEach(hearing.settings.activeCameras, id: \.self) { camera in
                    Toggle(isOn: Binding(get: { !service.settings.excludedCameras.contains(camera) },
                                         set: { service.setNamesAllowed(camera: camera, $0) })) {
                        Text("Names on \(pretty(camera))")
                    }
                }
            }
            if let message = service.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Speakers")
        } footer: {
            Text("Only indoor cameras with transcription on. “Staff present” stops this too. No emotion or tone analysis.")
        }
    }

    // MARK: People

    private var peopleSection: some View {
        Section {
            if service.profiles.isEmpty {
                Text("No one yet. Each person agrees first, then you pick 3 to 5 clips of their voice.")
                    .foregroundStyle(.secondary)
            }
            ForEach(service.profiles) { profile in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.name).font(.headline)
                            if profile.isChild { Text("Child").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                        }
                        Text("\(profile.sampleCount) samples · agreed \(profile.consent.acceptedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let face = profile.faceName {
                            Text("Frigate face: \(face)").font(.caption).foregroundStyle(.secondary)
                        }
                        if profile.needsReenrolment() {
                            Label("A child’s voice changes. Teach it again with new clips.", systemImage: "arrow.clockwise")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Teach from clips…") { teach = profile }
                        .disabled(!service.canEnableNew)
                    Button("Forget \(profile.name)…", role: .destructive) { forgetting = profile }
                        .accessibilityHint("Deletes this person’s voice samples and name")
                }
            }
            Button("Add a person…") { consentFor = NewPerson() }
                .disabled(!service.canEnableNew)
        } header: {
            Text("People")
        } footer: {
            Text("A voice sample is biometric data. It is encrypted and never leaves this Mac.")
        }
    }

    // MARK: Unknown voices

    private var unknownSection: some View {
        Section {
            if service.clusters.isEmpty {
                Text("Voices nobody named yet appear here after they are heard.").foregroundStyle(.secondary)
            }
            ForEach(service.clusters) { cluster in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cluster.ignored ? String(localized: "Ignored voice #\(cluster.id)") : String(localized: "Unknown voice #\(cluster.id)"))
                            .font(.headline)
                        Text("Heard \(cluster.events) times · last \(cluster.lastHeard.formatted(date: .abbreviated, time: .shortened)) · \(pretty(cluster.lastCamera))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let s = service.suggestions.first(where: { $0.clusterID == cluster.id }) {
                            suggestionRow(s)
                        }
                    }
                    Spacer()
                    Menu("Actions") {
                        Menu("This is…") {
                            ForEach(service.profiles) { p in
                                Button(p.name) { Task { await service.name(cluster: cluster.id, as: p.id) } }
                            }
                            Divider()
                            Button("Someone new…") {
                                pendingCluster = cluster.id
                                consentFor = NewPerson()
                            }
                        }
                        .disabled(!service.canEnableNew)
                        Menu("Same voice as…") {
                            ForEach(service.clusters.filter { $0.id != cluster.id }) { other in
                                Button(String(localized: "Unknown voice #\(other.id)")) {
                                    Task { await service.merge(cluster.id, into: other.id) }
                                }
                            }
                        }
                        Button(cluster.ignored ? "Stop ignoring" : "Ignore (TV, radio…)") {
                            Task { await service.setIgnored(cluster.id, !cluster.ignored) }
                        }
                        Divider()
                        Button("Forget this voice", role: .destructive) { Task { await service.forget(cluster: cluster.id) } }
                    }
                    .fixedSize()
                }
            }
        } header: {
            Text("Unknown voices")
        } footer: {
            Text("Forgotten automatically when not heard for \(hearing.settings.retentionDays) days. A guest is never given a household name unless the match is very sure.")
        }
    }

    @ViewBuilder private func suggestionRow(_ s: FaceVoiceSuggestion) -> some View {
        HStack(spacing: 8) {
            Label("Heard \(s.agreeing) times with \(s.face)’s face. Is it \(s.face)?", systemImage: "face.smiling")
                .font(.caption)
            if let person = service.profile(forFace: s.face) {
                Button("Yes") { Task { await service.name(cluster: s.clusterID, as: person.id) } }
                    .disabled(!service.canEnableNew)
            } else {
                Button("Yes…") {
                    pendingCluster = s.clusterID
                    consentFor = NewPerson(name: s.face, faceName: s.face)
                }
                .disabled(!service.canEnableNew)
            }
            Button("No") { Task { await service.rejectSuggestion(s) } }
        }
        .buttonStyle(.link)
    }

    // MARK: Model and storage

    private var modelSection: some View {
        Section {
            HStack {
                Text("Speaker model (pyannote community-1, 21 MB)")
                Spacer()
                switch service.modelState {
                case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .downloading(let f): ProgressView(value: f).frame(width: 120)
                case .unsupported(let why): Text(why).foregroundStyle(.secondary)
                case .failed(let why): Text(why).foregroundStyle(.orange)
                case .unknown, .notDownloaded:
                    Button("Download") { Task { await service.downloadModel() } }
                }
            }
            if let r = service.lastReport {
                Text(String(format: String(localized: "Last event: %d speakers, %d named, %.2f s for %.1f s of speech."),
                            r.speakers, r.identified, r.processingSeconds, r.audioSeconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: "pyannote speaker-diarization-community-1 (WeSpeaker, BUT Speech@FIT PLDA) — CC BY 4.0, Core ML by FluidInference · FluidAudio — Apache 2.0")
                .font(.caption2).foregroundStyle(.secondary)
        } header: {
            Text("Model")
        }
    }

    private var storageSection: some View {
        Section {
            if let error = service.storeError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button("Delete all voices…", role: .destructive) { confirmDeleteAll = true }
        } header: {
            Text("Storage")
        } footer: {
            Text("Speaker labels follow the transcript retention. People stay until someone presses “Forget” next to their name.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<VoiceSettings, Bool>) -> Binding<Bool> {
        Binding(get: { service.settings[keyPath: keyPath] }, set: { v in service.update { $0[keyPath: keyPath] = v } })
    }

    private func pretty(_ camera: String) -> String { camera.replacingOccurrences(of: "_", with: " ").capitalized }
}

/// Explicit, recorded consent of the person whose voice is learned
/// (GDPR art. 9(2)(a)). Shown in French or English — the person picks the
/// language they read; the date and language are stored.
struct VoiceConsentSheet: View {
    let onAccept: (_ name: String, _ face: String?, _ child: Bool, _ language: String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var face: String
    @State private var child = false
    @State private var agreed = false
    @State private var language: String

    init(initialName: String, initialFace: String,
         onAccept: @escaping (_ name: String, _ face: String?, _ child: Bool, _ language: String) -> Void,
         onCancel: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _face = State(initialValue: initialFace)
        _language = State(initialValue: Locale.current.language.languageCode?.identifier == "fr" ? "fr" : "en")
    }

    private var who: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "…" : name }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(selection: $language) {
                Text(verbatim: "Français").tag("fr")
                Text(verbatim: "English").tag("en")
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(verbatim: ConsentText.title(language, who)).font(.title2.weight(.bold))
            ForEach(Array(ConsentText.points(language).enumerated()), id: \.offset) { _, point in
                Label { Text(verbatim: point.1) } icon: { Image(systemName: point.0).frame(width: 22) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Labels stay visible once the fields are filled in.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: ConsentText.nameField(language)).gridColumnAlignment(.trailing)
                    TextField(text: $name) { Text(verbatim: ConsentText.nameField(language)) }
                        .labelsHidden()
                }
                GridRow {
                    Text(verbatim: ConsentText.faceField(language))
                    TextField(text: $face, prompt: Text(verbatim: ConsentText.optional(language))) {
                        Text(verbatim: ConsentText.faceField(language))
                    }
                    .labelsHidden()
                }
            }
            Toggle(isOn: $child) { Text(verbatim: ConsentText.child(language)) }.toggleStyle(.checkbox)
            Toggle(isOn: $agreed) { Text(verbatim: ConsentText.agree(language, who, child)) }
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button(role: .cancel, action: onCancel) { Text(verbatim: ConsentText.cancel(language)) }
                Button {
                    let f = face.trimmingCharacters(in: .whitespaces)
                    onAccept(name, f.isEmpty ? nil : f, child, language)
                } label: { Text(verbatim: ConsentText.accept(language)) }
                .keyboardShortcut(.defaultAction)
                .disabled(!agreed || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

/// Both languages are needed at once (the person may not read the Mac's
/// language), so this text lives here, not in the string catalog.
/// Bump `VoiceSettings.consentVersion` when it changes materially.
enum ConsentText {
    static func title(_ l: String, _ who: String) -> String {
        l == "fr" ? "Reconnaissance de la voix de \(who)" : "Voice recognition for \(who)"
    }

    static func points(_ l: String) -> [(String, String)] {
        l == "fr" ? [
            ("waveform", "Lumen Hub apprend votre voix à partir de 3 à 5 extraits des caméras intérieures, pour écrire votre prénom à la place de « S1 » dans les transcriptions."),
            ("lock.shield", "On enregistre une empreinte vocale (des nombres calculés depuis votre voix). C’est une donnée biométrique (RGPD, art. 9). Elle est chiffrée et reste sur ce Mac. Rien n’est envoyé à LorisLabs, Apple ou un cloud."),
            ("hand.raised", "Elle sert seulement à afficher votre prénom. Elle n’ouvre, ne déverrouille et n’autorise jamais rien."),
            ("waveform.slash", "Aucune analyse d’émotion ou de ton. Jamais avec les caméras extérieures, ni en mode « Personnel présent »."),
            ("trash", "Vous pouvez retirer votre accord à tout moment : « Oublier » à côté de votre prénom efface votre empreinte et votre prénom de toutes les transcriptions."),
        ] : [
            ("waveform", "Lumen Hub learns your voice from 3 to 5 clips from the indoor cameras, so transcripts show your name instead of “S1”."),
            ("lock.shield", "A voice signature is stored (numbers computed from your voice). This is biometric data (GDPR, art. 9). It is encrypted and stays on this Mac. Nothing is sent to LorisLabs, Apple or a cloud."),
            ("hand.raised", "It is only used to show your name. It never opens, unlocks or allows anything."),
            ("waveform.slash", "No emotion or tone analysis. Never with outdoor cameras, nor in “Staff present” mode."),
            ("trash", "You can withdraw at any time: “Forget” next to your name deletes your voice signature and your name from every transcript."),
        ]
    }

    static func nameField(_ l: String) -> String { l == "fr" ? "Prénom" : "Name" }
    static func faceField(_ l: String) -> String { l == "fr" ? "Visage Frigate" : "Frigate face" }
    static func optional(_ l: String) -> String { l == "fr" ? "Facultatif" : "Optional" }
    static func child(_ l: String) -> String {
        l == "fr" ? "Enfant de moins de 15 ans : un parent donne l’accord" : "Child under 15: a parent gives consent"
    }
    static func agree(_ l: String, _ who: String, _ child: Bool) -> String {
        switch (l == "fr", child) {
        case (true, false): return "Je suis \(who) et j’accepte que Lumen Hub enregistre mon empreinte vocale pour cet usage."
        case (true, true): return "Je suis le parent de \(who) et j’accepte que Lumen Hub enregistre son empreinte vocale pour cet usage."
        case (false, false): return "I am \(who) and I agree that Lumen Hub stores my voice signature for this use."
        case (false, true): return "I am \(who)’s parent and I agree that Lumen Hub stores their voice signature for this use."
        }
    }
    static func cancel(_ l: String) -> String { l == "fr" ? "Annuler" : "Cancel" }
    static func accept(_ l: String) -> String { l == "fr" ? "J’accepte" : "I agree" }
}

/// "Teach from clips": pick 3–5 real clips of this person.
struct TeachVoiceSheet: View {
    let service: VoiceService
    let profile: VoiceProfile
    let onDone: () -> Void
    @State private var candidates: [VoiceService.Candidate] = []
    @State private var picked = Set<String>()
    @State private var working = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Teach \(profile.name)’s voice").font(.title2.weight(.bold))
            Text("Pick 3 to 5 clips where only \(profile.name) speaks for that speaker. Clips from different cameras work best.")
                .foregroundStyle(.secondary)
            if loaded && candidates.isEmpty {
                ContentUnavailableView("No clips yet", systemImage: "waveform",
                                       description: Text("Speech heard by the indoor cameras appears here once speakers are separated."))
            } else {
                List(candidates) { c in
                    Toggle(isOn: Binding(get: { picked.contains(c.id) },
                                         set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.display) · \(c.event.camera.replacingOccurrences(of: "_", with: " ").capitalized) · \(c.event.start.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(c.excerpt).lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!picked.contains(c.id) && picked.count >= VoiceEnroller.sampleRange.upperBound)
                }
                .frame(minHeight: 260)
            }
            if let message = service.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("\(picked.count) of 3–5").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                Button("Save voice") {
                    working = true
                    let samples = candidates.filter { picked.contains($0.id) }.map { VoiceEnroller.Sample(event: $0.event, speaker: $0.speaker) }
                    Task {
                        let ok = await service.enroll(profile.id, samples: samples)
                        working = false
                        if ok { onDone() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !VoiceEnroller.sampleRange.contains(picked.count))
            }
        }
        .padding(22)
        .frame(width: 620, height: 520)
        .task {
            candidates = await service.candidates()
            loaded = true
        }
    }
}

/// Shown on Hub pages when Lumen Pro is not confirmed.
struct HubProBanner: View {
    let status: HubProStatus

    var body: some View {
        if !status.access.canEnableNew {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lumen Pro needed").font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "star.circle.fill").foregroundStyle(.orange)
                }
                Button("Check again") { Task { await status.refresh() } }
            }
        }
    }

    private var detail: String {
        switch status.access {
        case .notPro:
            return String(localized: "Lumen Pro is not active on this iCloud account. Listening is paused. Your transcripts and voices are kept.")
        case .unknown(.containerNotEntitled):
            return String(localized: "This build of Lumen Hub cannot read your Lumen Pro status yet. You cannot turn on new features; what already runs keeps running.")
        case .unknown(.noICloudAccount):
            return String(localized: "Sign in to iCloud with the account you use in Lumen.")
        case .unknown(.noRecord):
            return String(localized: "Open Lumen on your iPhone once, with iCloud on, so Lumen Hub can see your Pro status.")
        case .unknown:
            return String(localized: "Lumen Pro could not be checked. You cannot turn on new features until it is.")
        default:
            return ""
        }
    }
}
#endif
