#if LUMEN_HUB
import Foundation
import FrigateKit
import LumenHearing
import LumenHearingFluid
import Observation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Hearing")

/// Lumen Hub · speech transcription (Phase 1). Owns the settings, the local
/// transcript database, ONE shared engine per kind and the serial queue.
/// Everything stays on this Mac; only "Keyword heard on <camera>" may leave
/// it, through the owner's own push channel, with no words in it.
@MainActor @Observable
final class HearingService {
    static let shared = HearingService()

    enum ModelState: Equatable {
        case unknown, notDownloaded, downloading(Double), ready, unsupported(String), failed(String)
    }

    private(set) var settings: HearingSettings
    private(set) var cameras: [String] = []
    private(set) var cameraError: String?
    private(set) var queue = HearingPipeline.Snapshot()
    private(set) var parakeetState: ModelState = .unknown
    private(set) var appleState: ModelState = .unknown
    private(set) var storeError: String?
    private(set) var lastAlertNote: String?
    private(set) var transcripts: [TranscriptRecord] = []
    private(set) var transcriptCount = 0
    /// Set when turning something on was refused because Lumen Pro is not confirmed.
    private(set) var proBlocked = false

    /// Set by the coordinator: delivers a keyword alert through the Hub's push channel.
    @ObservationIgnored var alertHandler: (@MainActor (KeywordAlert) async -> String)?

    @ObservationIgnored private let settingsStore = HearingSettingsStore()
    @ObservationIgnored private let liveSettings: LiveSettings
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let parakeet: ParakeetEngine
    @ObservationIgnored private let silero: SileroVoiceGate
    @ObservationIgnored private let apple: (any TranscriptionEngine)?
    @ObservationIgnored private let frigate = HearingFrigateSource()
    @ObservationIgnored private var store: TranscriptStore?
    @ObservationIgnored private var pipeline: HearingPipeline?
    @ObservationIgnored private var ingestor: SpeechEventIngestor?
    @ObservationIgnored private var housekeeping: Task<Void, Never>?
    @ObservationIgnored private var started = false

    nonisolated static let cursorKey = "lumenhub.hearing.cursor.v1"

    private init() {
        let loaded = settingsStore.load()
        settings = loaded
        liveSettings = LiveSettings(loaded)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Lumen Hub/Hearing", isDirectory: true)
        let modelsRoot = HearingModelLocation.root(default: root.appendingPathComponent("Models", isDirectory: true))
        parakeet = ParakeetEngine(modelsRoot: modelsRoot)
        silero = SileroVoiceGate(modelsRoot: modelsRoot)
        if #available(macOS 26.0, *) { apple = AppleSpeechEngine() } else { apple = nil }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        do {
            store = try TranscriptStore(url: root.appendingPathComponent("transcripts.sqlite"))
        } catch {
            storeError = String(localized: "The transcript database could not open.")
            logger.error("store open failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard let store else { return }
        let live = liveSettings
        let silero = silero
        let sink = ServiceAlertSink()
        // Lumen Pro gate (read-only CloudKit check) and Phase 2 voices.
        HubProStatus.shared.start()
        HubProStatus.shared.onChange { [weak self] _ in
            self?.proBlocked = false
            self?.applyRunningState()
        }
        let speakers = VoiceService.shared.makeStage(hearing: { live.value }, frigate: frigate)
        let pipeline = HearingPipeline(
            settings: { live.value },
            audioSource: frigate,
            // Silero once downloaded (with Parakeet); a simple energy gate until then.
            gate: { () async -> any VoiceActivityGate in
                if await silero.isDownloaded { return silero }
                return EnergyVoiceGate()
            },
            engines: EngineSelector(parakeet: parakeet, apple: apple),
            speakers: speakers,
            store: store, alerts: sink)
        self.pipeline = pipeline
        Task { [weak self] in
            await pipeline.observe { snapshot in
                Task { @MainActor in self?.queue = snapshot }
            }
        }
        ingestor = SpeechEventIngestor(
            feed: frigate, pipeline: pipeline,
            loadCursor: {
                let t = UserDefaults.standard.double(forKey: Self.cursorKey)
                return t > 0 ? Date(timeIntervalSince1970: t) : nil
            },
            saveCursor: { UserDefaults.standard.set($0.timeIntervalSince1970, forKey: Self.cursorKey) })
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                await self?.purgeExpired()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        applyRunningState()
        Task { await refreshEngineStates() }
    }

    /// Starts or stops ingestion to match the settings. Off, staff present or
    /// no eligible camera → nothing is polled and the queue is emptied.
    private func applyRunningState() {
        guard let ingestor, let pipeline else { return }
        // A definite "not Pro" pauses work (data is kept); "unknown" does not.
        let shouldRun = !settings.activeCameras.isEmpty && HubProStatus.shared.access.allowsProcessing
        Task {
            if shouldRun {
                await ingestor.start()
            } else {
                await ingestor.stop()
                await pipeline.cancelPending()
                // A later restart must not backfill what happened while it was off.
                UserDefaults.standard.removeObject(forKey: Self.cursorKey)
            }
        }
    }

    // MARK: Settings

    func update(_ change: (inout HearingSettings) throws -> Void) rethrows {
        var next = settings
        try change(&next)
        guard next != settings else { return }
        // Pro gate: anything newly switched on needs a confirmed Lumen Pro.
        // Turning things off, staff mode and retention always work.
        // Leaving staff mode only resumes cameras already on, so it is ignored here.
        var after = next, before = settings
        after.staffPresent = false
        before.staffPresent = false
        let turnsOn = (next.enabled && !settings.enabled)
            || !Set(after.activeCameras).isSubset(of: Set(before.activeCameras))
        if turnsOn && !HubProStatus.shared.access.canEnableNew {
            proBlocked = true
            return
        }
        proBlocked = false
        let retentionChanged = next.retentionDays != settings.retentionDays
        settings = next
        liveSettings.value = next
        settingsStore.save(next)
        applyRunningState()
        if retentionChanged { Task { await purgeExpired() } }
    }

    func grantConsent(camera: String, placement: CameraPlacement) throws {
        try update { try $0.grantConsent(camera: camera, placement: placement) }
    }

    func placement(for camera: String) -> CameraPlacement? {
        settings.cameras[camera]?.placement
    }

    // MARK: Ingestion from the coordinator (MQTT `end` events)

    func noteSpeechEventEnded(id: String, camera: String, start: Date) {
        guard let ingestor, settings.eligibility(camera: camera, eventStart: start) == .allowed else { return }
        let event = SpeechEvent(id: id, camera: camera, start: start, end: Date())
        Task { await ingestor.noteEnded(event) }
    }

    func deliver(_ alert: KeywordAlert) async {
        guard let alertHandler else { return }
        lastAlertNote = await alertHandler(alert)
    }

    // MARK: Cameras

    func refreshCameras() async {
        do {
            cameras = try await frigate.cameraNames()
            cameraError = nil
        } catch {
            cameraError = BridgeFrigateEndpoint.message(for: error)
        }
    }

    // MARK: Engines

    func refreshEngineStates() async {
        switch await parakeet.readiness() {
        case .ready: parakeetState = .ready
        case .notDownloaded: if case .downloading = parakeetState {} else { parakeetState = .notDownloaded }
        case .unsupported(let why): parakeetState = .unsupported(why)
        }
        guard let apple else {
            appleState = .unsupported(String(localized: "Needs macOS 26 or later"))
            return
        }
        switch await apple.readiness() {
        case .ready: appleState = .ready
        case .notDownloaded: appleState = .notDownloaded
        case .unsupported(let why): appleState = .unsupported(why)
        }
    }

    func downloadParakeet() async {
        guard parakeetState != .ready else { return }
        parakeetState = .downloading(0)
        do {
            try await parakeet.prepare { fraction in
                Task { @MainActor in HearingService.shared.parakeetState = .downloading(fraction) }
            }
            try await silero.prepare()
            parakeetState = .ready
        } catch {
            parakeetState = .failed(String(localized: "Download failed. Check the network and try again."))
            logger.error("parakeet prepare failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func prepareApple() async {
        guard let apple else { return }
        appleState = .downloading(0)
        do {
            try await apple.prepare(progress: nil)
        } catch {
            appleState = .failed(String(localized: "macOS could not install the speech model."))
            return
        }
        await refreshEngineStates()
    }

    // MARK: Transcripts

    func search(_ query: String, camera: String? = nil) async {
        guard let store else { return }
        do {
            transcripts = try await store.search(query, camera: camera, limit: 200)
            transcriptCount = try await store.count()
        } catch {
            storeError = String(localized: "Search failed.")
        }
    }

    /// Newest transcripts, for the Voices page ("teach from clips").
    func recent(limit: Int) async -> [TranscriptRecord] {
        guard let store else { return [] }
        return (try? await store.recent(limit: limit)) ?? []
    }

    func deleteAllTranscripts() async {
        guard let store else { return }
        try? await store.deleteAll()
        transcripts = []
        transcriptCount = 0
    }

    private func purgeExpired() async {
        guard let store else { return }
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let removed = (try? await store.purge(olderThan: cutoff)) ?? 0
        if removed > 0 { logger.info("purged \(removed) expired transcripts") }
        transcriptCount = (try? await store.count()) ?? transcriptCount
    }
}

/// Thread-safe copy of the settings the background pipeline reads.
private final class LiveSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HearingSettings
    init(_ value: HearingSettings) { stored = value }
    var value: HearingSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Bridges the package's sink protocol to the main-actor service.
private struct ServiceAlertSink: KeywordAlertSink {
    func keywordHeard(_ alert: KeywordAlert) async {
        await HearingService.shared.deliver(alert)
    }
}

/// Frigate access for transcription: reuses the Hub's web address, Keychain
/// login and authenticated session (same as the HomeKit camera module).
actor HearingFrigateSource: SpeechEventFeed, SpeechAudioSource {
    private var session: BridgeFrigateSession?
    private var base: String?

    /// Internal so the Voices module reuses the same session (face events).
    func current() async throws -> BridgeFrigateSession {
        guard let raw = UserDefaults.standard.string(forKey: BridgeCoordinator.frigateWebURLKey),
              let normalized = BridgeFrigateEndpoint.normalized(raw) else { throw BridgeFrigateAccessError.invalidAddress }
        if let session, base == normalized { return session }
        let credentials = try await BridgeFrigateCredentialStore().load(for: normalized)
        let fresh = try BridgeFrigateSession(base: normalized, credentials: credentials)
        session = fresh
        base = normalized
        return fresh
    }

    func cameraNames() async throws -> [String] {
        try await current().cameraNames()
    }

    func speechEvents(after: Date, limit: Int) async throws -> [SpeechEvent] {
        try await current().speechEvents(after: after.timeIntervalSince1970, limit: limit).compactMap { e in
            guard e.label == "speech" else { return nil }
            return SpeechEvent(id: e.id, camera: e.camera, start: Date(timeIntervalSince1970: e.startTime),
                               end: e.endTime.map(Date.init(timeIntervalSince1970:)))
        }
    }

    func audio(for event: SpeechEvent) async throws -> PCMAudio {
        guard event.isWellFormed else { throw HearingError.invalidEvent }
        let file: URL
        do {
            file = try await current().eventClip(id: event.id)
        } catch ClipDownloadFailure.http(let status) where status == 400 || status == 404 {
            // Frigate answers 400 "No recordings found" until the segment is saved.
            throw HearingError.clipNotReady
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return try await AudioDecoder.decode16kMono(url: file)
    }
}
#endif
