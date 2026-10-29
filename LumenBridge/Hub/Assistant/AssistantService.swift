#if LUMEN_HUB
import CryptoKit
import Foundation
import LorisSecurity
import LumenAssistant
import LumenAssistantFluid
import LumenHearing
import LumenHearingFluid
import Observation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Assistant")

/// Localized string from the assistant's own table (Assistant.xcstrings), kept
/// apart from Localizable.xcstrings so this module merges cleanly.
func AL(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: "Assistant")
}

/// Lumen Hub · hands-free assistant. Owns the settings, the device registry,
/// the audit log and one listening task per opted-in indoor camera. Audio and
/// words stay on this Mac; only a short result ("Lumière du salon allumée")
/// goes to the owner's iPhone through the Hub's push channel.
@MainActor @Observable
final class AssistantService {
    static let shared = AssistantService()

    enum Connection: Equatable { case unknown, checking, ok(Int), failed(String) }

    private(set) var settings: AssistantSettings
    private(set) var registry: DeviceRegistry
    private(set) var audit: [AuditEntry] = []
    private(set) var auditIntegrity: String?
    private(set) var proposals: [ActionProposal] = []
    private(set) var homeAssistant: Connection = .unknown
    private(set) var llm: Connection = .unknown
    private(set) var hasToken = false
    private(set) var listening: [String: String] = [:]
    private(set) var lastResult: String?
    private(set) var canUndo = false
    private(set) var proBlocked = false

    @ObservationIgnored private let settingsStore = AssistantSettingsStore()
    @ObservationIgnored private let registryStore = DeviceRegistryStore()
    @ObservationIgnored private let live: LiveValue<AssistantSettings>
    @ObservationIgnored private let liveRegistry: LiveValue<DeviceRegistry>
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let frigate = HearingFrigateSource()
    @ObservationIgnored private var engine: AssistantEngine?
    @ObservationIgnored private var log: AuditLog?
    @ObservationIgnored private var book: ProposalBook?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false

    private init() {
        let loaded = settingsStore.load()
        settings = loaded
        live = LiveValue(loaded)
        let reg = registryStore.load()
        registry = reg
        liveRegistry = LiveValue(reg)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Lumen Hub/Assistant", isDirectory: true)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Task { await open() }
    }

    private func open() async {
        do {
            log = try AuditLog(url: root.appendingPathComponent("audit.jsonl"))
        } catch {
            lastResult = AL("The assistant log could not open.")
            return
        }
        // Pairing key for T2 receipts (the iPhone side will hold the same key).
        let keyStore = try? KeychainSymmetricKeyStore(
            store: SecureStore(),
            key: KeychainItemKey(service: "com.lorislabapp.lumenhub.assistant.v1", account: "proposal-key",
                                 accessGroup: "TDV6D5L785.com.lorislabapp.lumenbridge"),
            policy: .background)
        let key = (try? await keyStore?.loadOrCreate()) ?? SymmetricKey(size: .bits256)
        let book = ProposalBook(key: key)
        self.book = book
        hasToken = (try? await HATokenStore().load()) != nil

        let live = live, liveRegistry = liveRegistry
        let hearing = HearingService.shared
        let voices = VoiceService.shared
        let frigate = frigate
        let speaker: any UtteranceSpeakerIdentifier
        if let store = await voices.assistantVoiceStore() {
            speaker = HearingVoiceIdentifier(
                diarizer: voices.diarizer, store: store,
                hearing: { await MainActor.run { HearingService.shared.settings } },
                voices: { await MainActor.run { VoiceService.shared.settings } },
                proAllows: { await MainActor.run { HubProStatus.shared.access.allowsProcessing } })
        } else {
            speaker = NoSpeakerIdentifier()
        }
        let deps = AssistantEngine.Dependencies(
            settings: { live.value },
            hearing: { await MainActor.run { HearingService.shared.settings } },
            registry: { liveRegistry.value },
            proAllows: { await MainActor.run { HubProStatus.shared.access.allowsProcessing } },
            recognizer: hearing.sharedParakeet,
            backend: HomeAssistantFactory.backend(url: live.value.homeAssistantURL),
            llm: URL(string: live.value.llmURL).map { LlamaServerLLM(baseURL: $0) },
            speaker: speaker,
            presence: FrigatePresence(frigate: frigate),
            notifier: AssistantPushNotifier(),
            speech: SystemSpeechOutput(),
            verifier: LookService.shared.assistantVerifier)
        let engine = AssistantEngine(dependencies: deps, audit: log!, proposals: book)
        LookService.shared.attach(engine: engine)
        await engine.observe { outcome in
            Task { @MainActor in AssistantService.shared.note(outcome) }
        }
        self.engine = engine
        await refreshAudit()
        applyRunningState()
    }

    /// Rebuilds the engine when the HA or LLM address changes.
    private func rebuild() {
        engine = nil
        stopAll()
        started = false
        start()
    }

    // MARK: Listening

    private func applyRunningState() {
        guard let engine else { return }
        let wanted: Set<String> = settings.enabled && HubProStatus.shared.access.allowsProcessing ? settings.cameras : []
        for (camera, task) in tasks where !wanted.contains(camera) {
            task.cancel()
            tasks[camera] = nil
            listening[camera] = nil
        }
        let modelsRoot = HearingService.shared.modelsRoot
        for camera in wanted where tasks[camera] == nil {
            let frigate = frigate
            listening[camera] = AL("Connecting…")
            tasks[camera] = Task.detached {
                await Self.listen(camera: camera, engine: engine, frigate: frigate, modelsRoot: modelsRoot)
            }
        }
    }

    private func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        listening = [:]
    }

    /// One camera: go2rtc stream → VAD → utterances, reconnecting with backoff.
    nonisolated private static func listen(camera: String, engine: AssistantEngine, frigate: HearingFrigateSource,
                                           modelsRoot: URL) async {
        var backoff: Double = 5
        let detector = SileroFrameDetector(modelsRoot: modelsRoot)
        while !Task.isCancelled {
            guard await engine.isListening(camera: camera) else {
                await MainActor.run { AssistantService.shared.listening[camera] = AL("Paused (camera not eligible)") }
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            let source = Go2rtcAudioSource(camera: camera) {
                let stream = try await frigate.current().video(camera: camera)
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            var batch = Data()
                            batch.reserveCapacity(4096)
                            for try await byte in stream.bytes {
                                batch.append(byte)
                                if batch.count >= 4096 {
                                    continuation.yield(batch)
                                    batch.removeAll(keepingCapacity: true)
                                }
                            }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel(); stream.cancel() }
                }
            }
            let utterances = UtteranceStream(source: source, detector: detector,
                                             isListening: { await engine.isListening(camera: camera) })
            await MainActor.run { AssistantService.shared.listening[camera] = AL("Listening") }
            do {
                try await utterances.run { utterance in _ = await engine.handle(utterance) }
                backoff = 5
            } catch is CancellationError {
                return
            } catch {
                logger.error("assistant audio \(camera, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
                let text = (error as? FMP4Error).map { _ in AL("No AAC audio on this camera stream") } ?? AL("Audio stream lost, retrying")
                await MainActor.run { AssistantService.shared.listening[camera] = text }
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(60, backoff * 2)
        }
    }

    private func note(_ outcome: AssistantOutcome) {
        switch outcome.kind {
        case .ignored: return
        case .refused(let reason): lastResult = AL("Refused") + " · " + reason.rawValue
        case .failed(let why): lastResult = AL("Failed") + " · " + why
        default: lastResult = outcome.reply
        }
        Task {
            await refreshAudit()
            canUndo = await engine?.canUndo ?? false
        }
    }

    // MARK: Settings

    func update(_ change: (inout AssistantSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let turnsOn = (next.enabled && !settings.enabled) || !next.cameras.isSubset(of: settings.cameras)
            || (next.mode == .natural && settings.mode != .natural)
        if turnsOn && !HubProStatus.shared.access.canEnableNew {
            proBlocked = true
            return
        }
        proBlocked = false
        let needsRebuild = next.homeAssistantURL != settings.homeAssistantURL || next.llmURL != settings.llmURL
        settings = next
        live.value = next
        settingsStore.save(next)
        if needsRebuild { rebuild() } else { applyRunningState() }
    }

    /// Whether LumenHearing allows listening on this camera, and why not.
    func eligibility(camera: String) -> Eligibility {
        HearingService.shared.settings.eligibility(camera: camera)
    }

    // MARK: Home Assistant

    func saveToken(_ token: String) async {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try await HATokenStore().save(clean)
            hasToken = true
            await testHomeAssistant()
        } catch {
            homeAssistant = .failed(AL("The token could not be saved in the Keychain."))
        }
    }

    func removeToken() async {
        try? await HATokenStore().remove()
        hasToken = false
        homeAssistant = .unknown
    }

    func testHomeAssistant() async {
        guard let backend = HomeAssistantFactory.backend(url: settings.homeAssistantURL) else {
            homeAssistant = .failed(AL("Enter the Home Assistant address (http://…:8123)."))
            return
        }
        homeAssistant = .checking
        do {
            try await backend.verify()
            let count = try await backend.states().count
            homeAssistant = .ok(count)
        } catch HomeAssistantError.unauthorized {
            homeAssistant = .failed(AL("Home Assistant refused the token."))
        } catch HomeAssistantError.insecureTransport {
            homeAssistant = .failed(AL("Use https, or a local network address."))
        } catch {
            homeAssistant = .failed(AL("Home Assistant did not answer."))
        }
    }

    /// Pulls entities (and areas when the token is an admin's) into the registry.
    /// New devices arrive not exposed: the owner chooses.
    func syncDevices() async {
        guard let backend = HomeAssistantFactory.backend(url: settings.homeAssistantURL) else { return }
        do {
            let entities = try await backend.states()
            let areas = await backend.areas(for: entities.map(\.entityID))
            setRegistry(RegistrySync.merge(entities, areas: areas, into: registry))
            homeAssistant = .ok(entities.count)
        } catch {
            homeAssistant = .failed(AL("Home Assistant did not answer."))
        }
    }

    func setExposed(_ id: String, _ on: Bool) {
        var next = registry
        guard let i = next.devices.firstIndex(where: { $0.entityID == id }) else { return }
        next.devices[i].exposed = on
        setRegistry(next)
    }

    func setRoom(_ id: String, _ room: String?) {
        var next = registry
        guard let i = next.devices.firstIndex(where: { $0.entityID == id }) else { return }
        next.devices[i].room = room
        setRegistry(next)
    }

    func setAliases(_ id: String, _ text: String) {
        var next = registry
        guard let i = next.devices.firstIndex(where: { $0.entityID == id }) else { return }
        next.devices[i].aliases = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        setRegistry(next)
    }

    func addRoom(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, registry.room(named: clean) == nil else { return }
        var next = registry
        next.rooms.append(Room(name: clean))
        setRegistry(next)
    }

    func toggleCamera(_ camera: String, room: String) {
        var next = registry
        guard let i = next.rooms.firstIndex(where: { $0.name == room }) else { return }
        if next.rooms[i].cameras.contains(camera) { next.rooms[i].cameras.removeAll { $0 == camera } }
        else { next.rooms[i].cameras.append(camera) }
        setRegistry(next)
    }

    private func setRegistry(_ next: DeviceRegistry) {
        registry = next
        liveRegistry.value = next
        registryStore.save(next)
    }

    // MARK: LLM

    func testLLM() async {
        guard let url = URL(string: settings.llmURL) else { llm = .failed(AL("Invalid address")); return }
        llm = .checking
        llm = await LlamaServerLLM(baseURL: url).isReachable() ? .ok(0) : .failed(AL("llama-server is not running."))
    }

    // MARK: Audit, undo, proposals

    func refreshAudit() async {
        guard let log else { return }
        audit = await log.last(100)
        do {
            try await log.verifyOnDisk()
            auditIntegrity = nil
        } catch {
            auditIntegrity = AL("The log was changed outside Lumen Hub (chain broken).")
        }
        proposals = await book?.all ?? []
        let cutoff = Date().addingTimeInterval(-Double(settings.auditRetentionDays) * 86_400)
        _ = try? await log.purge(olderThan: cutoff)
    }

    func undoLast() async {
        guard let engine else { return }
        _ = await engine.undoLast()
        canUndo = await engine.canUndo
        await refreshAudit()
    }

    func dismiss(_ proposal: ActionProposal) async {
        await book?.dismiss(proposal.id)
        proposals = await book?.all ?? []
    }

    func deleteLog() async {
        try? await log?.deleteAll()
        await refreshAudit()
    }
}

/// Thread-safe copy read by the background pipeline.
final class LiveValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Home Assistant long-lived token in the Keychain (LorisSecurity), never logged.
struct HATokenStore: Sendable {
    private let store = SecureStore()
    private let key = KeychainItemKey(service: "com.lorislabapp.lumenhub.homeassistant.v1", account: "long-lived-token",
                                      accessGroup: "TDV6D5L785.com.lorislabapp.lumenbridge")
    func load() async throws -> String? {
        guard let secret = try await store.read(key, expecting: .background) else { return nil }
        return String(data: secret.dataCopy(), encoding: .utf8)
    }
    func save(_ token: String) async throws {
        try await store.upsert(Secret(bytes: Data(token.utf8)), for: key, policy: .background)
    }
    func remove() async throws { try await store.remove(key) }
}

enum HomeAssistantFactory {
    static func backend(url raw: String) -> HomeAssistantClient? {
        guard let base = URLSessionHATransport.normalizedBase(raw) else { return nil }
        return HomeAssistantClient(transport: URLSessionHATransport(baseURL: base) {
            guard let token = try await HATokenStore().load() else { throw HomeAssistantError.unauthorized }
            return token
        })
    }
}

/// "Someone in that room?" from Frigate person events on the room's cameras.
struct FrigatePresence: PresenceOracle {
    let frigate: HearingFrigateSource
    func personSeen(cameras: [String], within seconds: TimeInterval) async -> Bool? {
        let now = Date().timeIntervalSince1970
        var anyAnswer = false
        for camera in cameras {
            guard let events = try? await frigate.current().personEvents(camera: camera, after: now - 3600, before: now,
                                                                         limit: 20) else { continue }
            anyAnswer = true
            // In view now (no end yet) or seen in the last `seconds`.
            if events.contains(where: { $0.label == "person" && ($0.endTime == nil || $0.endTime! >= now - seconds) }) {
                return true
            }
        }
        return anyAnswer ? false : nil
    }
}

/// Short result to the owner's iPhone on the Hub's push channel. Never what was heard.
struct AssistantPushNotifier: AssistantNotifier {
    func notify(_ notice: AssistantNotice) async {
        let envelope: [String: Any] = [
            "source": "lumen-hub",
            "sourceSchema": "frigate-review-v1",
            "reviewId": "assistant-" + (notice.proposalID?.uuidString ?? UUID().uuidString),
            "reviewSeverity": notice.kind == .proposal ? "alert" : "detection",
            "eventId": "assistant-" + UUID().uuidString,
            "camera": notice.camera,
            "label": "assistant",
            "detected_at": Date().timeIntervalSince1970,
            "score": 1.0,
            "zones": [String](),
            "has_clip": false,
            "custom_title": notice.title,
            "custom_body": notice.body,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        let outcome = await MailboxPushSender().send(envelopeJSON: body)
        logger.info("assistant push: \(String(describing: outcome), privacy: .public)")
    }
}
#endif
