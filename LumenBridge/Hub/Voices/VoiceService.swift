#if LUMEN_HUB
import CryptoKit
import Foundation
import FrigateKit
import LorisSecurity
import LumenHearing
import LumenHearingFluid
import Observation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Voices")

/// Lumen Hub · Phase 2 voices. Owns the voice settings, the sealed voice
/// database and the diarizer, and hands the pipeline its speaker stage.
/// Voice templates are GDPR art. 9 biometric data: they exist only for people
/// who consented, stay on this Mac (sealed with a this-device-only Keychain
/// key) and are never sent anywhere. Voice ID only labels lines.
@MainActor @Observable
final class VoiceService {
    static let shared = VoiceService()
    typealias ModelState = HearingService.ModelState

    private(set) var settings: VoiceSettings
    private(set) var profiles: [VoiceProfile] = []
    private(set) var clusters: [UnknownVoiceCluster] = []
    private(set) var suggestions: [FaceVoiceSuggestion] = []
    private(set) var modelState: ModelState = .unknown
    private(set) var lastReport: VoiceAttributor.Report?
    private(set) var storeError: String?
    /// Result of the last owner action, shown under the action.
    private(set) var message: String?
    /// event id → speaker → display, for the transcripts list.
    private(set) var labels: [String: [String: SpeakerDisplay]] = [:]

    @ObservationIgnored private let settingsStore = VoiceSettingsStore()
    @ObservationIgnored private let live: LiveVoiceSettings
    @ObservationIgnored private let root: URL
    @ObservationIgnored let diarizer: FluidSpeakerDiarizer
    @ObservationIgnored private var store: VoiceStore?
    @ObservationIgnored private var attributor: VoiceAttributor?
    @ObservationIgnored private var enroller: VoiceEnroller?
    @ObservationIgnored private var opening: Task<VoiceAttributor?, Never>?
    @ObservationIgnored private var housekeeping: Task<Void, Never>?
    /// Debug screens harness only: fixture state, nothing saved.
    @ObservationIgnored private var isFixture = false

    private init() {
        let loaded = settingsStore.load()
        settings = loaded
        live = LiveVoiceSettings(loaded)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Lumen Hub/Hearing", isDirectory: true)
        diarizer = FluidSpeakerDiarizer(modelsRoot: HearingModelLocation.root(default: root.appendingPathComponent("Models", isDirectory: true)))
    }

    // MARK: Pipeline stage

    /// Called once by HearingService.start(). The store opens asynchronously
    /// (Keychain key first); jobs that arrive meanwhile wait for it.
    func makeStage(hearing: @escaping @Sendable () async -> HearingSettings,
                   frigate: HearingFrigateSource) -> any SpeakerAttributionStage {
        let voices = live
        opening = Task { [weak self] in
            guard let self else { return nil }
            return await self.open(hearing: hearing, frigate: frigate, voices: voices)
        }
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.purgeExpired()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        Task { await refreshModelState() }
        return DeferredVoiceStage { await VoiceService.shared.readyAttributor() }
    }

    private func readyAttributor() async -> VoiceAttributor? { await opening?.value }

    /// For the assistant's per-utterance speaker check (read-only use of the gallery).
    func assistantVoiceStore() async -> VoiceStore? {
        _ = await opening?.value
        return store
    }

    private func open(hearing: @escaping @Sendable () async -> HearingSettings, frigate: HearingFrigateSource,
                      voices: LiveVoiceSettings) async -> VoiceAttributor? {
        var opened: VoiceStore?
        do {
            let keyStore = try KeychainSymmetricKeyStore(
                store: SecureStore(),
                key: KeychainItemKey(service: "com.lorislabapp.lumenhub.voices.v1", account: "sealing-key",
                                     accessGroup: "TDV6D5L785.com.lorislabapp.lumenbridge"),
                policy: .background)
            let key = try await keyStore.loadOrCreate()
            opened = try VoiceStore(url: root.appendingPathComponent("voices.sqlite"), sealer: AESGCMVoiceSealer(key: key))
        } catch {
            storeError = String(localized: "The voice database could not open. Speakers are still separated, but not saved.")
            logger.error("voice store open failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        store = opened
        let stage = VoiceAttributor(
            diarizer: diarizer, store: opened, hearing: hearing, voices: { voices.value },
            proAllows: { await MainActor.run { HubProStatus.shared.access.allowsProcessing } },
            faces: frigate)
        await stage.observe { report in
            Task { @MainActor in
                VoiceService.shared.lastReport = report
                await VoiceService.shared.refresh()
            }
        }
        attributor = stage
        if let opened {
            enroller = VoiceEnroller(audioSource: frigate, diarizer: diarizer, store: opened,
                                     minimumSpeech: { voices.value.thresholds.minimumSpeechSeconds })
        }
        await refresh()
        return stage
    }

    // MARK: Settings

    var canEnableNew: Bool { HubProStatus.shared.access.canEnableNew }

    func update(_ change: (inout VoiceSettings) -> Void) {
        var next = settings
        change(&next)
        next.thresholds = next.thresholds.validated
        guard next != settings else { return }
        // Pro gate: naming voices is a new Hub feature; switching off always works.
        if next.identificationEnabled && !settings.identificationEnabled && !canEnableNew {
            message = String(localized: "Lumen Pro is needed to turn this on.")
            return
        }
        settings = next
        live.value = next
        guard !isFixture else { return }
        settingsStore.save(next)
    }

    func setNamesAllowed(camera: String, _ allowed: Bool) {
        update {
            if allowed { $0.excludedCameras.remove(camera) } else { $0.excludedCameras.insert(camera) }
        }
    }

    // MARK: Model

    func refreshModelState() async {
        guard !isFixture else { return }
        switch await diarizer.readiness() {
        case .ready: modelState = .ready
        case .notDownloaded: if case .downloading = modelState {} else { modelState = .notDownloaded }
        case .unsupported(let why): modelState = .unsupported(why)
        }
    }

    func downloadModel() async {
        guard modelState != .ready else { return }
        modelState = .downloading(0)
        do {
            try await diarizer.prepare { fraction in
                Task { @MainActor in VoiceService.shared.modelState = .downloading(fraction) }
            }
            modelState = .ready
        } catch {
            modelState = .failed(String(localized: "Download failed. Check the network and try again."))
        }
    }

    // MARK: People (consent first)

    /// Creates a person after the consent sheet. Returns nil when refused.
    func addPerson(name: String, faceName: String?, isChild: Bool, consentLanguage: String) async -> VoiceProfile? {
        guard canEnableNew else {
            message = String(localized: "Lumen Pro is needed to add a voice.")
            return nil
        }
        guard let store else { return nil }
        do {
            let profile = try await store.addProfile(name: name, faceName: faceName, isChild: isChild,
                                                     consent: VoiceConsent(language: consentLanguage))
            await refresh()
            return profile
        } catch {
            message = String(localized: "This person could not be added.")
            return nil
        }
    }

    func updatePerson(_ id: String, faceName: String?, isChild: Bool) async {
        try? await store?.updateProfile(id: id, faceName: .some(faceName), isChild: isChild)
        await refresh()
    }

    func enroll(_ profileID: String, samples: [VoiceEnroller.Sample]) async -> Bool {
        guard canEnableNew else {
            message = String(localized: "Lumen Pro is needed to teach a voice.")
            return false
        }
        guard let enroller else { return false }
        guard modelState == .ready else {
            message = String(localized: "Download the speaker model first.")
            return false
        }
        do {
            let n = try await enroller.enroll(profileID: profileID, samples: samples)
            message = String(localized: "\(n) voice samples saved.")
            await refresh()
            return true
        } catch VoiceEnroller.EnrolError.tooShort {
            message = String(localized: "One clip has too little speech from this person. Pick a longer one.")
        } catch VoiceEnroller.EnrolError.needsThreeToFiveClips {
            message = String(localized: "Pick 3 to 5 clips.")
        } catch {
            message = String(localized: "The clips could not be read. Frigate may have deleted them.")
        }
        return false
    }

    /// "Forget <name>": samples, name, face link and labels of this person.
    func forget(_ profileID: String) async {
        try? await store?.forget(profileID: profileID)
        message = String(localized: "Voice and name deleted.")
        await refresh()
    }

    // MARK: Unknown voices

    func name(cluster: Int64, as profileID: String) async {
        do {
            try await store?.assignCluster(cluster, to: profileID)
            message = String(localized: "Voice named.")
        } catch {
            message = String(localized: "This voice could not be named.")
        }
        await refresh()
    }

    func merge(_ absorb: Int64, into keep: Int64) async {
        try? await store?.mergeClusters(keep: keep, absorb: absorb)
        await refresh()
    }

    func setIgnored(_ cluster: Int64, _ ignored: Bool) async {
        try? await store?.setIgnored(clusterID: cluster, ignored)
        await refresh()
    }

    func forget(cluster: Int64) async {
        try? await store?.forgetCluster(cluster)
        await refresh()
    }

    func rejectSuggestion(_ suggestion: FaceVoiceSuggestion) async {
        try? await store?.clearFaceEvidence(clusterID: suggestion.clusterID)
        await refresh()
    }

    /// The existing person whose face name matches a suggestion, if any.
    func profile(forFace face: String) -> VoiceProfile? {
        profiles.first { $0.faceName?.compare(face, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func deleteEverything() async {
        try? await store?.deleteAll()
        labels = [:]
        message = String(localized: "Every voice, name and speaker label was deleted.")
        await refresh()
    }

    #if DEBUG
    /// Screens harness only: a throwaway store sealed with an in-memory key
    /// (no Keychain), fixture settings, nothing saved.
    func installScreenFixture(settings: VoiceSettings, store: VoiceStore, modelState: ModelState) async {
        isFixture = true
        self.settings = settings
        live.value = settings
        self.store = store
        self.modelState = modelState
        storeError = nil
        message = nil
        await refresh()
    }
    #endif

    // MARK: Reads

    func refresh() async {
        guard let store else { return }
        profiles = (try? await store.profiles()) ?? []
        clusters = (try? await store.clusters()) ?? []
        suggestions = (try? await store.faceSuggestions()) ?? []
    }

    func refreshLabels(eventIDs: [String]) async {
        guard let store, !eventIDs.isEmpty else { return }
        let fresh = (try? await store.labels(eventIDs: eventIDs)) ?? [:]
        labels.merge(fresh) { _, new in new }
    }

    struct Candidate: Identifiable, Hashable {
        var event: SpeechEvent
        var speaker: String
        var excerpt: String
        var seconds: Double
        var display: String
        var id: String { "\(event.id)|\(speaker)" }
    }

    /// Recent clips with at least 2 s from one speaker, for "teach from clips".
    func candidates() async -> [Candidate] {
        guard let store else { return [] }
        let records = await HearingService.shared.recent(limit: 150)
        await refreshLabels(eventIDs: records.map(\.eventID))
        var out: [Candidate] = []
        for record in records {
            let turns = (try? await store.turns(eventID: record.eventID)) ?? []
            for speaker in Set(turns.map(\.speaker)).sorted() {
                // Never teach a person from a voice the owner marked as TV or radio.
                if labels[record.eventID]?[speaker]?.band == .ignored { continue }
                let seconds = turns.filter { $0.speaker == speaker }.reduce(0) { $0 + $1.duration }
                guard seconds >= settings.thresholds.minimumSpeechSeconds else { continue }
                let text = record.segments.filter { $0.speaker == speaker }.map(\.text).joined(separator: " ")
                out.append(Candidate(event: SpeechEvent(id: record.eventID, camera: record.camera, start: record.start, end: record.end),
                                     speaker: speaker, excerpt: text.isEmpty ? record.text : text, seconds: seconds,
                                     display: display(labels[record.eventID]?[speaker], speaker: speaker)))
            }
        }
        return out
    }

    /// "Marie", "Marie?", "Unknown voice #3", "Ignored voice" or "S1".
    func display(_ label: SpeakerDisplay?, speaker: String) -> String {
        guard let label else { return speaker }
        switch label.band {
        case .match?, .confirmed?: return label.name ?? speaker
        case .maybe?: return label.name.map { String(localized: "\($0)?") } ?? speaker
        case .ignored?: return String(localized: "Ignored voice")
        case .unknown?: return label.clusterID.map { String(localized: "Unknown voice #\($0)") } ?? speaker
        case nil: return speaker
        }
    }

    private func purgeExpired() async {
        guard let store else { return }
        let days = HearingService.shared.settings.retentionDays
        _ = try? await store.purge(olderThan: Date().addingTimeInterval(-Double(days) * 86_400))
        _ = try? await store.consolidate(threshold: settings.thresholds.validated.clusterJoin)
        await refresh()
    }
}

/// Thread-safe copy of the voice settings for the background stage.
final class LiveVoiceSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VoiceSettings
    init(_ value: VoiceSettings) { stored = value }
    var value: VoiceSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Waits for the voice store to open, then delegates to the real stage.
private struct DeferredVoiceStage: SpeakerAttributionStage {
    let resolve: @Sendable () async -> VoiceAttributor?
    func attribute(_ transcript: EngineTranscript, audio: PCMAudio) async throws -> EngineTranscript { transcript }
    func attribute(_ transcript: EngineTranscript, audio: PCMAudio, context: SpeakerContext) async throws -> EngineTranscript {
        guard let stage = await resolve() else { return transcript }
        return try await stage.attribute(transcript, audio: audio, context: context)
    }
}

/// Recognised faces (Frigate `sub_label`) on person events overlapping a speech event.
extension HearingFrigateSource: FaceSightingSource {
    func faces(camera: String, from: Date, to: Date) async throws -> [FaceSighting] {
        // A person event that started up to 10 minutes earlier may still be on screen.
        let events = try await current().personEvents(camera: camera, after: from.timeIntervalSince1970 - 600,
                                                      before: to.timeIntervalSince1970, limit: 50)
        return events.compactMap { e in
            guard e.label == "person", let name = e.subLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return FaceSighting(name: name, start: Date(timeIntervalSince1970: e.startTime),
                                end: e.endTime.map(Date.init(timeIntervalSince1970:)))
        }
    }
}
#endif
