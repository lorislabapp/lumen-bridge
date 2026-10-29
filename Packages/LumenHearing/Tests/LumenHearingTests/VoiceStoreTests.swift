import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import LumenHearing

func testSealer() -> AESGCMVoiceSealer { AESGCMVoiceSealer(key: SymmetricKey(size: .bits256)) }
let fr = VoiceConsent(acceptedAt: Date(timeIntervalSince1970: 1_000), language: "fr")

@Suite struct VoiceStoreMigrationTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString)/voices.sqlite")
    }

    @Test func freshDatabaseReachesLatestSchemaAndReopens() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sealer = testSealer()
        do {
            let store = try VoiceStore(url: url, sealer: sealer)
            #expect(try await store.schemaVersionOnDisk() == VoiceStore.schemaVersion)
            try await store.addProfile(name: "Marie", isChild: false, consent: fr)
        }
        let again = try VoiceStore(url: url, sealer: sealer)
        #expect(try await again.profiles().map(\.name) == ["Marie"])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func versionOneDataSurvivesTheUpgrade() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sealer = testSealer()
        do {
            let v1 = try VoiceStore(url: url, sealer: sealer, migrateTo: 1)
            #expect(try await v1.schemaVersionOnDisk() == 1)
        }
        // Write a v1 row the way a v1 build would have.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO speaker_segments(event_id, camera, event_start, speaker, start, end, created) VALUES ('e1','salon',10,'S1',0,2,10)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let v2 = try VoiceStore(url: url, sealer: sealer)
        #expect(try await v2.schemaVersionOnDisk() == 2)
        #expect(try await v2.turns(eventID: "e1") == [SpeakerTurn(speaker: "S1", start: 0, end: 2)])
        #expect(try await v2.labels(eventIDs: ["e1"])["e1"]?["S1"]?.band == nil)
    }

    @Test func refusesADatabaseFromANewerBuild() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try VoiceStore(url: url, sealer: testSealer())
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: VoiceStoreError.newerDatabase(99)) { try VoiceStore(url: url, sealer: testSealer()) }
    }

    @Test func embeddingsAreSealedOnDisk() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let marker = VoiceVector([0.125, 0.25, 0.5, 0.75])!
        do {
            let store = try VoiceStore(url: url, sealer: testSealer())
            let p = try await store.addProfile(name: "Marie", isChild: false, consent: fr)
            try await store.addEmbeddings(profileID: p.id, [.init(vector: marker, camera: "salon", source: "event", speechSeconds: 4)])
        }
        var raw = Data()
        for suffix in ["", "-wal"] { raw += (try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix))) ?? Data() }
        #expect(raw.range(of: marker.data) == nil)
        // A different key cannot read the samples back.
        let other = try VoiceStore(url: url, sealer: testSealer())
        #expect(try await other.gallery().isEmpty)
    }
}

@Suite struct VoiceStoreConsentTests {
    @Test func noProfileWithoutACurrentConsent() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        await #expect(throws: VoiceStoreError.consentRequired) {
            try await store.addProfile(name: "Marie", isChild: false, consent: VoiceConsent(version: 0, language: "fr"))
        }
        await #expect(throws: VoiceStoreError.consentRequired) {
            try await store.addProfile(name: "Marie", isChild: false, consent: VoiceConsent(language: "de"))
        }
        await #expect(throws: VoiceStoreError.invalidName) {
            try await store.addProfile(name: "  ", isChild: false, consent: fr)
        }
        let p = try await store.addProfile(name: "Marie", isChild: false, consent: fr)
        #expect(p.consent.acceptedAt == fr.acceptedAt && p.consent.language == "fr")
        #expect(try await store.consentLog(profileID: p.id) == ["granted"])
    }

    @Test func enrolmentNeedsThreeToFiveDistinctClipsAndConsent() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let enroller = VoiceEnroller(audioSource: SilentSource(), diarizer: FakeDiarizer(), store: store)
        let event = { (id: String) in SpeechEvent(id: id, camera: "salon", start: Date(), end: nil) }
        await #expect(throws: VoiceEnroller.EnrolError.needsThreeToFiveClips) {
            try await enroller.enroll(profileID: "x", samples: [.init(event: event("1"), speaker: "S1")])
        }
        let same = (0..<3).map { _ in VoiceEnroller.Sample(event: event("1"), speaker: "S1") }
        await #expect(throws: VoiceEnroller.EnrolError.sameEventTwice) { try await enroller.enroll(profileID: "x", samples: same) }
        let three = ["1", "2", "3"].map { VoiceEnroller.Sample(event: event($0), speaker: "S1") }
        await #expect(throws: VoiceEnroller.EnrolError.consentRequired) { try await enroller.enroll(profileID: "nobody", samples: three) }
    }

    @Test func enrolmentFromPickedClipsStoresOneSamplePerClip() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let p = try await store.addProfile(name: "Marie", isChild: false, consent: fr)
        var samples: [VoiceEnroller.Sample] = []
        for id in ["e1", "e2", "e3"] {
            try await store.recordEvent(eventID: id, camera: "salon", eventStart: Date(), turns: [SpeakerTurn(speaker: "S2", start: 1, end: 5)],
                                        assignments: [SpeakerAssignment(speaker: "S2")])
            samples.append(.init(event: SpeechEvent(id: id, camera: "salon", start: Date(), end: nil), speaker: "S2"))
        }
        let diarizer = FakeDiarizer(result: Diarization(turns: [SpeakerTurn(speaker: "A", start: 0, end: 4)],
                                                        speakers: [DiarizedSpeaker(label: "A", embedding: axis, speechSeconds: 4)],
                                                        audioSeconds: 4, processingSeconds: 0.01))
        let enroller = VoiceEnroller(audioSource: SilentSource(seconds: 8), diarizer: diarizer, store: store)
        #expect(try await enroller.enroll(profileID: p.id, samples: samples) == 3)
        #expect(try await store.profile(id: p.id).sampleCount == 3)
        // A speaker who never spoke in that event cannot be picked.
        let wrong = samples.map { VoiceEnroller.Sample(event: $0.event, speaker: "S9") }
        await #expect(throws: VoiceEnroller.EnrolError.speakerNotFound("e1")) { try await enroller.enroll(profileID: p.id, samples: wrong) }
    }
}

@Suite struct VoiceStoreForgetAndClusterTests {
    func filled() async throws -> (VoiceStore, VoiceProfile) {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let p = try await store.addProfile(name: "Marie", faceName: "marie", isChild: false, consent: fr)
        try await store.addEmbeddings(profileID: p.id, [.init(vector: axis, camera: "salon", source: "event", speechSeconds: 4),
                                                        .init(vector: vec(0.9), camera: "cuisine", source: "event", speechSeconds: 4)])
        try await store.recordEvent(eventID: "e1", camera: "salon", eventStart: Date(), turns: [SpeakerTurn(speaker: "S1", start: 0, end: 3)],
                                    assignments: [SpeakerAssignment(speaker: "S1", band: .match, profileID: p.id, score: 0.9)])
        return (store, p)
    }

    @Test func forgetMeErasesSamplesNameAndLabels() async throws {
        let (store, p) = try await filled()
        #expect(try await store.labels(eventIDs: ["e1"])["e1"]?["S1"]?.name == "Marie")
        let c = try await store.fileUnknown(vec(0.1), speechSeconds: 3, camera: "salon", eventID: "e2", speaker: "S1", threshold: 0.6)
        try await store.addFaceEvidence(clusterID: c.id, face: "Marie", eventID: "e2")

        try await store.forget(profileID: p.id)
        #expect(try await store.profiles().isEmpty)
        #expect(try await store.gallery().isEmpty)
        let label = try #require(try await store.labels(eventIDs: ["e1"])["e1"]?["S1"])
        #expect(label.name == nil && label.profileID == nil && label.band == nil)
        #expect(try await store.faceCounts(clusterID: c.id).isEmpty)
        #expect(try await store.consentLog(profileID: p.id) == ["withdrawn"])
        #expect(try await store.embeddingCount() == 1) // only the unrelated unknown voice remains
    }

    @Test func unknownVoicesClusterMergeIgnoreAndName() async throws {
        let (store, p) = try await filled()
        let a = try await store.fileUnknown(VoiceVector([0, 1, 0, 0])!, speechSeconds: 3, camera: "salon", eventID: "u1", speaker: "S1", threshold: 0.6)
        let a2 = try await store.fileUnknown(VoiceVector([0, 0.95, 0.1, 0])!, speechSeconds: 3, camera: "cuisine", eventID: "u2", speaker: "S1", threshold: 0.6)
        #expect(a.id == a2.id)
        let b = try await store.fileUnknown(VoiceVector([0, 0, 0, 1])!, speechSeconds: 2, camera: "salon", eventID: "u3", speaker: "S2", threshold: 0.6)
        #expect(b.id != a.id)
        #expect(try await store.clusters().first { $0.id == a.id }?.events == 2)

        try await store.mergeClusters(keep: a.id, absorb: b.id)
        let merged = try #require(try await store.clusters().first)
        #expect(try await store.clusters().count == 1)
        #expect(merged.events == 3 && merged.samples == 3)

        try await store.setIgnored(clusterID: a.id, true)
        #expect(try await store.clusters(includeIgnored: false).isEmpty)
        let again = try await store.fileUnknown(VoiceVector([0, 1, 0, 0])!, speechSeconds: 3, camera: "salon", eventID: "u4", speaker: "S1", threshold: 0.6)
        #expect(again.ignored)
        try await store.setIgnored(clusterID: a.id, false)

        try await store.recordEvent(eventID: "u1", camera: "salon", eventStart: Date(), turns: [SpeakerTurn(speaker: "S1", start: 0, end: 3)],
                                    assignments: [SpeakerAssignment(speaker: "S1", band: .unknown, clusterID: a.id)])
        try await store.assignCluster(a.id, to: p.id)
        #expect(try await store.clusters().isEmpty)
        #expect(try await store.profile(id: p.id).sampleCount == 2 + 4)
        #expect(try await store.labels(eventIDs: ["u1"])["u1"]?["S1"]?.band == .confirmed)
        #expect(try await store.labels(eventIDs: ["u1"])["u1"]?["S1"]?.name == "Marie")
    }

    @Test func clusterSamplesAreCapped() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        for i in 0..<20 {
            _ = try await store.fileUnknown(axis, speechSeconds: 3, camera: "salon", eventID: "e\(i)", speaker: "S1", threshold: 0.6)
        }
        let c = try #require(try await store.clusters().first)
        #expect(c.events == 20 && c.samples == VoiceStore.maxClusterSamples)
    }

    @Test func faceLinkPromotesAfterThreeAgreeingEventsIntoAConsentingAdultOnly() async throws {
        let (store, p) = try await filled()
        let c = try await store.fileUnknown(VoiceVector([0, 0, 1, 0])!, speechSeconds: 3, camera: "salon", eventID: "f1", speaker: "S1", threshold: 0.6)
        try await store.addFaceEvidence(clusterID: c.id, face: "Marie", eventID: "f1")
        try await store.addFaceEvidence(clusterID: c.id, face: "Marie", eventID: "f1") // same event counts once
        try await store.addFaceEvidence(clusterID: c.id, face: "Marie", eventID: "f2")
        #expect(try await store.promoteIfReady(clusterID: c.id) == nil)
        #expect(try await store.faceSuggestions() == [FaceVoiceSuggestion(clusterID: c.id, face: "Marie", agreeing: 2)])

        try await store.updateProfile(id: p.id, isChild: true)
        try await store.addFaceEvidence(clusterID: c.id, face: "Marie", eventID: "f3")
        #expect(try await store.promoteIfReady(clusterID: c.id) == nil) // children never auto-learn

        try await store.updateProfile(id: p.id, isChild: false)
        let promoted = try #require(try await store.promoteIfReady(clusterID: c.id))
        #expect(promoted.id == p.id && promoted.sampleCount == 3)
        #expect(try await store.clusters().isEmpty)
    }

    @Test func noFaceProfileMeansSuggestionOnly() async throws {
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let c = try await store.fileUnknown(axis, speechSeconds: 3, camera: "salon", eventID: "f1", speaker: "S1", threshold: 0.6)
        for e in ["f1", "f2", "f3"] { try await store.addFaceEvidence(clusterID: c.id, face: "Paul", eventID: e) }
        #expect(try await store.promoteIfReady(clusterID: c.id) == nil)
        #expect(try await store.faceSuggestions().first?.agreeing == 3)
    }

    @Test func retentionDropsLabelsAndStaleUnknownsButKeepsPeople() async throws {
        let (store, _) = try await filled()
        _ = try await store.fileUnknown(axis, speechSeconds: 3, camera: "salon", eventID: "old", speaker: "S1", threshold: 0.6,
                                        at: Date(timeIntervalSince1970: 10))
        try await store.purge(olderThan: Date().addingTimeInterval(3600))
        #expect(try await store.turns(eventID: "e1").isEmpty)
        #expect(try await store.clusters().isEmpty)
        #expect(try await store.profiles().count == 1)
        try await store.deleteAll()
        #expect(try await store.profiles().isEmpty)
        #expect(try await store.embeddingCount() == 0)
    }

    @Test func childNeedsReenrolment() {
        let consent = VoiceConsent(language: "en")
        var child = VoiceProfile(id: "c", name: "Léo", faceName: nil, isChild: true, consent: consent, created: Date(),
                                 enrolledAt: Date().addingTimeInterval(-200 * 86_400), sampleCount: 3)
        #expect(child.needsReenrolment())
        child.enrolledAt = Date()
        #expect(!child.needsReenrolment())
        child.isChild = false
        child.enrolledAt = nil
        #expect(!child.needsReenrolment())
    }
}

// MARK: Fakes

struct SilentSource: SpeechAudioSource {
    var seconds: Double = 6
    func audio(for event: SpeechEvent) async throws -> PCMAudio {
        PCMAudio(samples: (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) / 9)) * 0.3 })
    }
}

actor FakeDiarizer: SpeakerDiarizer {
    var result: Diarization
    var ready = true
    private(set) var calls = 0
    init(result: Diarization = Diarization(turns: [], speakers: [], audioSeconds: 0, processingSeconds: 0), ready: Bool = true) {
        self.result = result
        self.ready = ready
    }
    func set(_ r: Diarization) { result = r }
    func readiness() async -> EngineReadiness { ready ? .ready : .notDownloaded }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}
    func diarize(_ audio: PCMAudio) async throws -> Diarization {
        calls += 1
        return result
    }
}
