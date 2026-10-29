#if LUMEN_HUB
import CoreGraphics
import Foundation
import LumenAssistant
import LumenLook
import Observation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Look")

/// Localized string from the Look table (Look.xcstrings), kept apart so this module merges cleanly.
func LL(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: "Look")
}

/// Lumen Hub · Look: after the assistant acts, a camera checks the device really
/// changed. Areas, learned looks and short-lived proof frames stay on this Mac;
/// the push carries only the sentence ("Volets fermés — vérifié sur la caméra Salon").
@MainActor @Observable
final class LookService {
    static let shared = LookService()

    struct Prefs: Codable, Equatable {
        var enabled = true
        var useModel = true
        /// llama-server with a vision model (Qwen3-VL-4B + mmproj). Separate from the text model.
        var visionURL = "http://127.0.0.1:8012"
        var proofHours = 24.0
    }

    private(set) var prefs: Prefs
    private(set) var targets: [LookTarget] = []
    private(set) var lastResults: [String: LookResult] = [:]
    private(set) var testing: Set<String> = []
    private(set) var vision: AssistantService.Connection = .unknown

    @ObservationIgnored let store: LookStore
    @ObservationIgnored private(set) var verifier: LookVerifier!
    @ObservationIgnored private let frames = HubLookFrames()
    @ObservationIgnored private let engineBox = EngineBox()
    @ObservationIgnored private let livePrefs: LiveValue<Prefs>
    private static let prefsKey = "LumenHub.Look.prefs.v1"
    /// Under XCTest the Hub is a test host: Look never reads or prunes the owner's
    /// areas and proofs, and never saves settings. A throwaway folder is used instead.
    @ObservationIgnored private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #if DEBUG
    /// Screen fixture: synthetic snapshots per camera, nothing fetched from Frigate.
    @ObservationIgnored private var fixtureFrames: [String: CGImage]?
    #endif

    private init() {
        let testHost = isTestHost
        let loaded = testHost ? Prefs()
            : UserDefaults.standard.data(forKey: Self.prefsKey).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs()
        prefs = loaded
        livePrefs = LiveValue(loaded)
        let root = testHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("LumenHubLookTests-\(UUID().uuidString)", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lumen Hub/Look", isDirectory: true)
        store = LookStore(root: root, proofRetention: loaded.proofHours * 3600)
        let live = livePrefs, box = engineBox
        verifier = LookVerifier(dependencies: .init(
            frames: frames, store: store,
            judge: VisionJudgeProxy(prefs: live),
            device: HADeviceState(),
            retrier: EngineLookRetrier(box: box),
            notifier: LookPushNotifier(),
            settings: { let p = live.value; return LookSettings(enabled: p.enabled, useModel: p.useModel) }))
        Task { await self.load() }
    }

    /// The assistant's verifier seam.
    var assistantVerifier: any ActionVerifier { AssistantLookVerifier(verifier: verifier) }

    /// Called once the assistant engine exists: the retry goes through it.
    func attach(engine: AssistantEngine) {
        engineBox.engine = engine
    }

    private func load() async {
        await verifier.observe { result in
            Task { @MainActor in LookService.shared.lastResults[result.entityID] = result }
        }
        await store.prune()
        targets = await store.allTargets
        for t in targets { lastResults[t.entityID] = await store.last(for: t.entityID) }
    }

    // MARK: Areas

    func target(_ entityID: String) -> LookTarget? { targets.first { $0.entityID == entityID } }

    /// Default check kind for an assistant device (a plug may power a lamp: owner can change it).
    static func lookKind(for kind: DeviceKind) -> LookDeviceKind? {
        switch kind {
        case .light, .outlet: .light
        case .tv: .tv
        case .shutter: .shutter
        case .garageDoor: .door
        default: nil
        }
    }

    /// Latest frame for the area editor.
    func snapshot(camera: String) async throws -> CGImage {
        #if DEBUG
        if let fixtureFrames {
            guard let image = fixtureFrames[camera] else { throw LookFrameError.cameraOffline }
            return image
        }
        #endif
        guard !isTestHost else { throw LookFrameError.cameraOffline }
        return try await frames.frame(camera: camera, height: 720).image
    }

    func cameras() async -> [String] {
        #if DEBUG
        if let fixtureFrames { return fixtureFrames.keys.sorted() }
        #endif
        guard !isTestHost else { return [] }
        return (try? await frames.cameraNames()) ?? []
    }

    /// Saves the area and the frame it was drawn on (camera-moved reference).
    func save(entityID: String, name: String, kind: LookDeviceKind, camera: String, area: LookRect, travelSeconds: Double,
              frame: CGImage?) async {
        var t = target(entityID) ?? LookTarget(entityID: entityID, name: name, kind: kind, camera: camera, area: area)
        t.name = name
        t.kind = kind
        t.camera = camera
        t.area = area.clamped
        t.travelSeconds = travelSeconds
        await store.upsert(t)
        if let frame { await store.setReference(entityID, image: frame) }
        targets = await store.allTargets
    }

    func setTravel(_ entityID: String, seconds: Double) async {
        guard var t = target(entityID) else { return }
        t.travelSeconds = min(max(seconds, 0.5), 120)
        await store.upsert(t)
        targets = await store.allTargets
    }

    func setEnabled(_ entityID: String, _ on: Bool) async {
        guard var t = target(entityID) else { return }
        t.enabled = on
        await store.upsert(t)
        targets = await store.allTargets
    }

    func remove(_ entityID: String) async {
        await store.remove(entityID)
        lastResults[entityID] = nil
        targets = await store.allTargets
    }

    /// "Test": look now, no command, no push.
    func test(_ entityID: String) async {
        testing.insert(entityID)
        defer { testing.remove(entityID) }
        if let result = await verifier.testNow(entityID) {
            lastResults[entityID] = result
            logger.info("look test \(result.outcome.label, privacy: .public) \(result.timing.totalMs, privacy: .public) ms")
        }
    }

    func proof(_ name: String) async -> CGImage? {
        guard let data = await store.proof(name) else { return nil }
        return JPEG.decode(data)
    }

    // MARK: Settings

    func update(_ change: (inout Prefs) -> Void) {
        var next = prefs
        change(&next)
        guard next != prefs else { return }
        prefs = next
        livePrefs.value = next
        if !isTestHost, let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.prefsKey) }
        let hours = next.proofHours
        Task { await store.setRetention(hours * 3600) }
    }

    #if DEBUG
    /// Synthetic state for the opt-in screen tests: areas and results go to the
    /// throwaway test-host store, snapshots are drawn in memory, nothing is fetched.
    func installScreenFixture(prefs: Prefs, targets list: [LookTarget], results: [LookResult],
                              proofs: [String: CGImage], frames: [String: CGImage], vision: AssistantService.Connection) async {
        precondition(isTestHost, "Look screen fixture is for XCTest only")
        fixtureFrames = frames
        self.prefs = prefs
        livePrefs.value = prefs
        for old in await store.allTargets { await store.remove(old.entityID) }
        for t in list { await store.upsert(t) }
        targets = await store.allTargets
        lastResults = [:]
        for var r in results {
            if let image = proofs[r.entityID] { r.proofFile = await store.saveProof(image) }
            await store.record(r)
            lastResults[r.entityID] = r
        }
        self.vision = vision
    }
    #endif

    func testVision() async {
        guard let url = URL(string: prefs.visionURL) else { vision = .failed(LL("Invalid address")); return }
        vision = .checking
        vision = await LlamaServerJudge(baseURL: url).isAvailable() ? .ok(0) : .failed(LL("No vision model answers at this address."))
    }
}

// MARK: Adapters

/// LumenAssistant ⇄ LumenLook.
struct AssistantLookVerifier: ActionVerifier {
    let verifier: LookVerifier

    static func lookRequest(_ r: VerificationRequest) -> LookRequest? {
        guard let expected = LookState(rawValue: r.expectedState) else { return nil }
        return LookRequest(entityID: r.entityID, expected: expected, prior: r.priorState.flatMap(LookState.init(homeAssistant:)),
                           commandAt: r.commandAt, deadline: r.deadline, language: r.language)
    }

    func covers(_ request: VerificationRequest) async -> Bool {
        guard Self.lookRequest(request) != nil else { return false }
        return await verifier.covers(request.entityID)
    }

    func prepare(_ request: VerificationRequest) async {
        guard let r = Self.lookRequest(request) else { return }
        await verifier.prepare(r)
    }

    func verify(_ request: VerificationRequest) async {
        guard let r = Self.lookRequest(request) else { return }
        await verifier.verify(r)
    }
}

final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _engine: AssistantEngine?
    var engine: AssistantEngine? {
        get { lock.withLock { _engine } }
        set { lock.withLock { _engine = newValue } }
    }
}

/// One retry through the assistant (rate caps, preview mode, audit).
struct EngineLookRetrier: LookRetrier {
    let box: EngineBox
    func retry(_ request: LookRequest) async -> Bool {
        guard let engine = box.engine else { return false }
        let kind = await MainActor.run { AssistantService.shared.registry.devices.first { $0.entityID == request.entityID }?.kind }
        guard let kind else { return false }
        let camera = await MainActor.run { LookService.shared.target(request.entityID)?.camera }
        return await engine.reissue(VerificationRequest(entityID: request.entityID, kind: kind, camera: camera,
                                                        expectedState: request.expected.rawValue, deadline: Date(),
                                                        commandAt: Date(), language: request.language))
    }
}

/// Device-reported state from Home Assistant at check time.
struct HADeviceState: DeviceStateReader {
    func state(of entityID: String) async -> LookState? {
        let url = await MainActor.run { AssistantService.shared.settings.homeAssistantURL }
        guard let backend = HomeAssistantFactory.backend(url: url),
              let entity = try? await backend.state(entityID) else { return nil }
        return LookState(homeAssistant: entity.state)
    }
}

/// The push carries the sentence only; the proof frame stays on the Hub.
struct LookPushNotifier: LookNotifier {
    func deliver(_ result: LookResult, target: LookTarget) async {
        let notify = await MainActor.run { AssistantService.shared.settings.notifyPhone }
        guard notify else { return }
        let kind: AssistantNotice.Kind = switch result.outcome {
        case .confirmed: .done
        case .contradicted: .failed
        case .unknown: .answer
        }
        await AssistantPushNotifier().notify(AssistantNotice(kind: kind, title: target.name, body: result.message,
                                                             camera: target.camera))
    }
}

/// Vision model at the address in the Look settings (read per call).
struct VisionJudgeProxy: VisualJudge {
    let prefs: LiveValue<LookService.Prefs>
    private var judge: LlamaServerJudge? { URL(string: prefs.value.visionURL).map { LlamaServerJudge(baseURL: $0) } }
    func isAvailable() async -> Bool { await judge?.isAvailable() ?? false }
    func judge(_ question: JudgeQuestion) async throws -> JudgeAnswer {
        guard let judge else { throw JudgeError.unreachable }
        return try await judge.judge(question)
    }
}

/// Frigate frames for Look, through the Hub's Frigate session (same login, cookies, no redirects).
actor HubLookFrames: LookFrameSource {
    private let source = HearingFrigateSource()
    private var catalog: (Date, [String: Bool])?

    func cameraNames() async throws -> [String] { try await source.cameraNames() }

    func frame(camera: String, height: Int) async throws -> CameraFrame {
        let session: BridgeFrigateSession
        do { session = try await source.current() } catch { throw LookFrameError.cameraOffline }
        // Privacy: a camera turned off in Frigate is never woken to check.
        if catalog == nil || Date().timeIntervalSince(catalog!.0) > 60 {
            if let list = try? await session.cameraCatalog() {
                catalog = (Date(), Dictionary(list.map { ($0.id, $0.enabled) }, uniquingKeysWith: { a, _ in a }))
            }
        }
        if catalog?.1[camera] == false { throw LookFrameError.cameraDisabled }
        let data: Data, header: String?
        do { (data, header) = try await session.timedSnapshot(camera: camera, height: height) } catch BridgeFrigateAccessError.loginRequired {
            throw LookFrameError.unauthorized
        } catch {
            throw LookFrameError.cameraOffline
        }
        guard let image = JPEG.decode(data) else { throw LookFrameError.badImage }
        return CameraFrame(image: image, frameTime: JPEG.frameTime(header: header))
    }
}
#endif
