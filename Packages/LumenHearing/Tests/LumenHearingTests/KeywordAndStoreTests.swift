import Foundation
import Testing
@testable import LumenHearing

@Suite struct KeywordMatcherTests {
    @Test func frenchAccentsCaseAndPunctuationAreIgnored() {
        let m = KeywordMatcher(keywords: ["au secours", "Aidez-moi", "élève", "œuf", "help me"])
        #expect(m.matches(in: "AU SÉCOURS !") == ["au secours"])
        #expect(m.matches(in: "aidez moi, vite") == ["Aidez-moi"])
        #expect(m.matches(in: "L'ELEVE est là") == ["élève"])
        #expect(m.matches(in: "un OEUF") == ["œuf"])
        #expect(m.matches(in: "Please, HELP… me!") == ["help me"])
    }

    @Test func matchesWholeWordsOnly() {
        let m = KeywordMatcher(keywords: ["feu", "colis"])
        #expect(m.matches(in: "un feuilleton") == [])
        #expect(m.matches(in: "les colisages") == [])
        #expect(m.matches(in: "Au feu ! J'ai un colis.") == ["feu", "colis"])
    }

    @Test func apostrophesSplitWords() {
        let m = KeywordMatcher(keywords: ["aide"])
        #expect(m.matches(in: "j’ai besoin d’aide") == ["aide"])
    }

    @Test func emptyMatcherMatchesNothing() {
        #expect(KeywordMatcher(keywords: []).matches(in: "anything").isEmpty)
        #expect(KeywordMatcher.normalize("  Ça, c'est ÉTÉ !  ") == "ca c est ete")
    }
}

@Suite struct TranscriptStoreTests {
    static func transcript(_ text: String, engine: EngineKind = .appleSpeech) -> EngineTranscript {
        EngineTranscript(text: text, segments: [.init(start: 0.5, end: 2, text: text)], language: "fr",
                         engine: engine, audioSeconds: 2, processingSeconds: 0.1)
    }

    static func event(_ id: String, camera: String = "salon", at t: TimeInterval) -> SpeechEvent {
        SpeechEvent(id: id, camera: camera, start: Date(timeIntervalSince1970: t), end: Date(timeIntervalSince1970: t + 5))
    }

    @Test func ftsSearchIsAccentAndCaseInsensitiveWithPrefixes() async throws {
        let store = try TranscriptStore(url: nil)
        try await store.insert(.init(event: Self.event("e1", at: 1000), transcript: Self.transcript("Le facteur a déposé un colis")))
        try await store.insert(.init(event: Self.event("e2", camera: "cuisine", at: 2000), transcript: Self.transcript("On mange à quelle heure ?")))
        try await store.insert(.init(event: Self.event("e3", at: 3000), transcript: Self.transcript("Hello, open the door please")))

        #expect(try await store.search("DEPOSE").map(\.eventID) == ["e1"])
        #expect(try await store.search("fact").map(\.eventID) == ["e1"])
        #expect(try await store.search("colis facteur").map(\.eventID) == ["e1"])
        #expect(try await store.search("colis porte").isEmpty)
        #expect(try await store.search("door").first?.snippet?.contains("[door]") == true)
        #expect(try await store.search("mange", camera: "salon").isEmpty)
        #expect(try await store.search("mange", camera: "cuisine").map(\.eventID) == ["e2"])
        // Empty query → newest first.
        #expect(try await store.search("  ").map(\.eventID) == ["e3", "e2", "e1"])
        let record = try #require(try await store.search("hello").first)
        #expect(record.segments == [TranscriptSegment(start: 0.5, end: 2, text: "Hello, open the door please")])
        #expect(record.engine == EngineKind.appleSpeech.rawValue)
    }

    @Test func hostileQueriesCannotBreakFTSGrammar() async throws {
        let store = try TranscriptStore(url: nil)
        try await store.insert(.init(event: Self.event("e1", at: 1000), transcript: Self.transcript("rien")))
        for q in ["\"", "text:rien", "rien OR *", "NEAR(a b)", "'; DROP TABLE transcripts; --", "^rien", "(-)"] {
            _ = try await store.search(q)
        }
        #expect(try await store.count() == 1)
        #expect(TranscriptStore.ftsQuery("text:rien OR x") == "\"text\"* \"rien\"* \"or\"* \"x\"*")
    }

    @Test func retentionPurgeRemovesOldTranscriptsFromTableAndIndex() async throws {
        let store = try TranscriptStore(url: nil)
        try await store.insert(.init(event: Self.event("old", at: 1000), transcript: Self.transcript("ancien message"), created: Date(timeIntervalSince1970: 1000)))
        try await store.insert(.init(event: Self.event("new", at: 9000), transcript: Self.transcript("nouveau message"), created: Date(timeIntervalSince1970: 9000)))
        let removed = try await store.purge(olderThan: Date(timeIntervalSince1970: 5000))
        #expect(removed == 1)
        #expect(try await store.search("message").map(\.eventID) == ["new"])
        #expect(try await store.search("ancien").isEmpty)
        #expect(try await store.hasProcessed(eventID: "old") == false)
        #expect(try await store.hasProcessed(eventID: "new"))
    }

    @Test func processedMarksAndDeleteAll() async throws {
        let store = try TranscriptStore(url: nil)
        try await store.markProcessed(eventID: "x", status: .skipped)
        #expect(try await store.hasProcessed(eventID: "x"))
        try await store.insert(.init(event: Self.event("e1", at: 1), transcript: Self.transcript("bonjour")))
        try await store.deleteAll()
        #expect(try await store.count() == 0)
        #expect(try await store.search("bonjour").isEmpty)
        #expect(try await store.hasProcessed(eventID: "x") == false)
    }

    @Test func onDiskDatabaseIsPrivateToTheUser() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcripts.sqlite")
        do {
            let store = try TranscriptStore(url: url)
            try await store.insert(.init(event: Self.event("e1", at: 1), transcript: Self.transcript("persisté")))
        }
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let reopened = try TranscriptStore(url: url)
        #expect(try await reopened.search("persiste").count == 1)
    }
}
