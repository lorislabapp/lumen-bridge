import CryptoKit
import Foundation
import LumenHearing
import Testing
@testable import LumenAssistant

/// The seam to LumenLook: before-frame hook, honest reply, background check, one retry.
@Suite struct LookHookTests {
    actor RecordingVerifier: ActionVerifier {
        let watched: Set<String>
        let backend: MockHomeBackend
        private(set) var prepared: [VerificationRequest] = []
        private(set) var verified: [VerificationRequest] = []
        /// Backend calls already made when `prepare` ran (must be none: "before" means before).
        private(set) var callsAtPrepare: [Int] = []
        init(watched: Set<String>, backend: MockHomeBackend) {
            self.watched = watched
            self.backend = backend
        }
        func covers(_ request: VerificationRequest) async -> Bool { watched.contains(request.entityID) }
        func prepare(_ request: VerificationRequest) async {
            prepared.append(request)
            callsAtPrepare.append(await backend.calls.count)
        }
        func verify(_ request: VerificationRequest) async { verified.append(request) }
    }

    static func make(watched: Set<String>, settings: AssistantSettings = Fixture.settings())
        throws -> (AssistantEngine, MockHomeBackend, RecordingNotifier, RecordingVerifier, AuditLog) {
        let backend = MockHomeBackend()
        let notifier = RecordingNotifier()
        let verifier = RecordingVerifier(watched: watched, backend: backend)
        let audit = try AuditLog(url: tempURL("audit.jsonl"))
        let deps = AssistantEngine.Dependencies(
            settings: { settings }, hearing: { Fixture.hearing() }, registry: { Fixture.registry }, recognizer: nil,
            backend: backend, notifier: notifier, verifier: verifier)
        let engine = AssistantEngine(dependencies: deps, audit: audit, proposals: ProposalBook(key: SymmetricKey(size: .bits256)))
        return (engine, backend, notifier, verifier, audit)
    }

    @Test func watchedDeviceSaysCheckingAndPreparesBeforeActing() async throws {
        let (engine, backend, notifier, verifier, _) = try Self.make(watched: ["cover.volets_salon"])
        let out = await engine.handle(text: "Lumen, ferme les volets du salon", camera: "salon", audio: .silence(seconds: 1))
        #expect(out.kind == .executed)
        #expect(out.reply == "Commande envoyée, je vérifie sur la caméra")
        // No "done" push: the verified result is the notice.
        #expect(await notifier.notices.isEmpty)
        #expect(await verifier.callsAtPrepare == [0])
        let request = try #require(await verifier.verified.first)
        #expect(request.expectedState == "closed")
        #expect(request.priorState == "open")
        #expect(request.language == "fr")
        #expect(await backend.calls.count == 1)
    }

    @Test func unwatchedDeviceKeepsTheOldReply() async throws {
        let (engine, _, notifier, verifier, _) = try Self.make(watched: [])
        let out = await engine.handle(text: "Lumen, ferme les volets du salon", camera: "salon", audio: .silence(seconds: 1))
        #expect(out.reply == "Volet du salon fermé")
        #expect(await notifier.notices.count == 1)
        #expect(await verifier.prepared.isEmpty)
        #expect(await verifier.verified.count == 1) // verify still offered; the verifier decides
    }

    @Test func reissueSendsOnceThroughTheBackend() async throws {
        let (engine, backend, _, _, audit) = try Self.make(watched: ["light.salon_plafond"])
        let request = VerificationRequest(entityID: "light.salon_plafond", kind: .light, camera: "salon", expectedState: "on",
                                          deadline: Date())
        #expect(await engine.reissue(request))
        #expect(await backend.calls.map(\.service) == ["turn_on"])
        #expect(await audit.all.last?.speaker == "look-retry")
    }

    @Test func reissueRefusedInPreviewAndAboveT0() async throws {
        let (preview, previewBackend, _, _, _) = try Self.make(watched: [], settings: Fixture.settings(dryRun: true))
        let light = VerificationRequest(entityID: "light.salon_plafond", kind: .light, camera: "salon", expectedState: "on",
                                        deadline: Date())
        #expect(await !preview.reissue(light))
        #expect(await previewBackend.calls.isEmpty)
        let (engine, backend, _, _, _) = try Self.make(watched: [])
        let garage = VerificationRequest(entityID: "cover.garage", kind: .garageDoor, camera: nil, expectedState: "open",
                                         deadline: Date())
        #expect(await !engine.reissue(garage))
        #expect(await backend.calls.isEmpty)
    }
}
