import CryptoKit
import Foundation
import SQLite3

/// Seals embedding bytes before they reach the disk. The Hub keeps the key in
/// its own Keychain item (this device only, never synced); deleting the key
/// makes every stored voice unreadable at once.
public protocol VoiceSealer: Sendable {
    func seal(_ plain: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

public struct AESGCMVoiceSealer: VoiceSealer {
    private let key: SymmetricKey
    public init(key: SymmetricKey) { self.key = key }
    public init?(keyData: Data) {
        guard keyData.count == 32 else { return nil }
        key = SymmetricKey(data: keyData)
    }
    public static func newKeyData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    public func seal(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw HearingError.storage("seal") }
        return combined
    }

    public func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}

/// A person who agreed to be recognised by voice.
public struct VoiceProfile: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    /// Frigate face name (`sub_label`) of the same person, for face ↔ voice suggestions.
    public var faceName: String?
    /// Children: re-enrol prompt every `childReenrolDays`, never used for permissions, no auto-learning.
    public var isChild: Bool
    public var consent: VoiceConsent
    public var created: Date
    public var enrolledAt: Date?
    public var sampleCount: Int

    public static let childReenrolDays = 120

    /// True when a child's samples are old enough that their voice has likely changed.
    public func needsReenrolment(now: Date = Date()) -> Bool {
        guard isChild else { return false }
        guard let enrolledAt else { return true }
        return now.timeIntervalSince(enrolledAt) > Double(Self.childReenrolDays) * 86_400
    }
}

/// Explicit consent of the enrolled person (GDPR art. 9(2)(a)).
public struct VoiceConsent: Sendable, Equatable {
    public var acceptedAt: Date
    public var version: Int
    /// Language of the text the person read ("fr" or "en").
    public var language: String

    public init(acceptedAt: Date = Date(), version: Int = VoiceSettings.consentVersion, language: String) {
        self.acceptedAt = acceptedAt
        self.version = version
        self.language = language
    }

    public var isCurrent: Bool { version == VoiceSettings.consentVersion && ["fr", "en"].contains(language) }
}

public struct UnknownVoiceCluster: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var events: Int
    public var speechSeconds: Double
    public var firstHeard: Date
    public var lastHeard: Date
    public var lastCamera: String
    public var ignored: Bool
    public var samples: Int
}

/// "Unknown voice #3 was heard N times with Marie's face."
public struct FaceVoiceSuggestion: Sendable, Equatable, Identifiable {
    public var clusterID: Int64
    public var face: String
    public var agreeing: Int
    public var id: String { "\(clusterID)|\(face)" }
}

/// How one speaker of one event is shown.
public struct SpeakerDisplay: Sendable, Equatable {
    public var speaker: String
    public var band: VoiceBand?
    public var profileID: String?
    public var name: String?
    public var clusterID: Int64?
}

/// One speaker-turn row to record for an event.
public struct SpeakerAssignment: Sendable, Equatable {
    public var speaker: String
    public var band: VoiceBand?
    public var profileID: String?
    public var clusterID: Int64?
    public var score: Float?
    public init(speaker: String, band: VoiceBand? = nil, profileID: String? = nil, clusterID: Int64? = nil, score: Float? = nil) {
        self.speaker = speaker
        self.band = band
        self.profileID = profileID
        self.clusterID = clusterID
        self.score = score
    }
}

public enum VoiceStoreError: Error, Equatable, Sendable {
    case consentRequired
    case unknownProfile
    case unknownCluster
    case newerDatabase(Int32)
    case invalidName
}

/// Local voice database (`voices.sqlite`, separate from transcripts so it can
/// be wiped alone). SQLite, `secure_delete`, foreign keys, 0600, excluded
/// from backups; every embedding is AES-GCM sealed. Schema changes go
/// through numbered migrations (`PRAGMA user_version`).
public actor VoiceStore {
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }
    private let connection: Connection
    private var db: OpaquePointer? { connection.pointer }
    private let sealer: any VoiceSealer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Cap of samples kept per unknown cluster and per person and camera (newest kept,
    /// owner-picked enrolment samples are never pushed out by automatic ones).
    public static let maxClusterSamples = 8
    public static let maxAutoSamplesPerCamera = 6

    /// Numbered migrations. Never edit a shipped step; append a new one.
    static let migrations: [String] = [
        // 1 — diarization only: who spoke when, no template, no identity.
        """
        CREATE TABLE speaker_segments(
            id INTEGER PRIMARY KEY,
            event_id TEXT NOT NULL,
            camera TEXT NOT NULL,
            event_start REAL NOT NULL,
            speaker TEXT NOT NULL,
            start REAL NOT NULL,
            end REAL NOT NULL,
            created REAL NOT NULL
        );
        CREATE INDEX speaker_segments_event ON speaker_segments(event_id);
        CREATE INDEX speaker_segments_start ON speaker_segments(event_start);
        """,
        // 2 — opt-in named voices (GDPR art. 9: consent recorded per person).
        """
        CREATE TABLE voice_profiles(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            face_name TEXT,
            is_child INTEGER NOT NULL DEFAULT 0,
            consent_at REAL NOT NULL,
            consent_version INTEGER NOT NULL,
            consent_language TEXT NOT NULL,
            created REAL NOT NULL,
            enrolled_at REAL
        );
        CREATE TABLE unknown_clusters(
            id INTEGER PRIMARY KEY,
            centroid BLOB NOT NULL,
            events INTEGER NOT NULL,
            speech_seconds REAL NOT NULL,
            first_heard REAL NOT NULL,
            last_heard REAL NOT NULL,
            last_camera TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'open'
        );
        CREATE TABLE voice_embeddings(
            id INTEGER PRIMARY KEY,
            profile_id TEXT REFERENCES voice_profiles(id) ON DELETE CASCADE,
            cluster_id INTEGER REFERENCES unknown_clusters(id) ON DELETE CASCADE,
            camera TEXT,
            vector BLOB NOT NULL,
            source TEXT NOT NULL,
            event_id TEXT,
            speaker TEXT,
            speech_seconds REAL NOT NULL,
            created REAL NOT NULL,
            CHECK ((profile_id IS NULL) <> (cluster_id IS NULL))
        );
        CREATE INDEX voice_embeddings_profile ON voice_embeddings(profile_id);
        CREATE INDEX voice_embeddings_cluster ON voice_embeddings(cluster_id);
        ALTER TABLE speaker_segments ADD COLUMN profile_id TEXT REFERENCES voice_profiles(id) ON DELETE SET NULL;
        ALTER TABLE speaker_segments ADD COLUMN cluster_id INTEGER REFERENCES unknown_clusters(id) ON DELETE SET NULL;
        ALTER TABLE speaker_segments ADD COLUMN band TEXT;
        ALTER TABLE speaker_segments ADD COLUMN score REAL;
        CREATE TABLE face_voice_evidence(
            cluster_id INTEGER NOT NULL REFERENCES unknown_clusters(id) ON DELETE CASCADE,
            face_name TEXT NOT NULL,
            event_id TEXT NOT NULL,
            at REAL NOT NULL,
            PRIMARY KEY(cluster_id, event_id)
        );
        CREATE TABLE consent_log(
            id INTEGER PRIMARY KEY,
            profile_id TEXT NOT NULL,
            action TEXT NOT NULL,
            consent_version INTEGER,
            at REAL NOT NULL
        );
        """,
    ]
    public static var schemaVersion: Int32 { Int32(migrations.count) }

    /// `url == nil` opens a private in-memory database (tests).
    /// `migrateTo` stops at an older schema version (tests only).
    public init(url: URL?, sealer: any VoiceSealer, migrateTo target: Int32? = nil) throws {
        var handle: OpaquePointer?
        let path: String
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            path = url.path
        } else {
            path = ":memory:"
        }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw HearingError.storage(message)
        }
        connection = Connection(handle)
        self.sealer = sealer
        try Self.exec(handle, "PRAGMA journal_mode = WAL; PRAGMA secure_delete = ON; PRAGMA foreign_keys = ON;")
        try Self.migrate(handle, to: target ?? Self.schemaVersion)
        if let url {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
    }

    static func migrate(_ db: OpaquePointer, to target: Int32) throws {
        let current = try userVersion(db)
        if current > schemaVersion { throw VoiceStoreError.newerDatabase(current) }
        guard current < target else { return }
        for version in (current + 1)...min(target, schemaVersion) {
            try exec(db, "BEGIN IMMEDIATE;")
            do {
                try exec(db, migrations[Int(version) - 1])
                try exec(db, "PRAGMA user_version = \(version);")
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HearingError.storage("user_version")
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    public func schemaVersionOnDisk() throws -> Int32 {
        guard let db else { return 0 }
        return try Self.userVersion(db)
    }

    // MARK: Profiles (consent first)

    @discardableResult
    public func addProfile(name: String, faceName: String? = nil, isChild: Bool, consent: VoiceConsent,
                           at date: Date = Date()) throws -> VoiceProfile {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(clean.count) else { throw VoiceStoreError.invalidName }
        guard consent.isCurrent else { throw VoiceStoreError.consentRequired }
        let id = UUID().uuidString.lowercased()
        let face = faceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try run("""
            INSERT INTO voice_profiles(id, name, face_name, is_child, consent_at, consent_version, consent_language, created)
            VALUES (?,?,?,?,?,?,?,?)
            """, [.text(id), .text(clean), face.map { .text($0) } ?? .null, .int(isChild ? 1 : 0),
                  .real(consent.acceptedAt.timeIntervalSince1970), .int(Int64(consent.version)),
                  .text(consent.language), .real(date.timeIntervalSince1970)])
        try logConsent(profileID: id, action: "granted", version: consent.version, at: consent.acceptedAt)
        return try profile(id: id)
    }

    public func profiles() throws -> [VoiceProfile] {
        try query("\(Self.profileSelect) ORDER BY p.name COLLATE NOCASE", [], Self.profileRow)
    }

    public func profile(id: String) throws -> VoiceProfile {
        guard let p = try query("\(Self.profileSelect) WHERE p.id = ?", [.text(id)], Self.profileRow).first else {
            throw VoiceStoreError.unknownProfile
        }
        return p
    }

    public func updateProfile(id: String, name: String? = nil, faceName: String?? = nil, isChild: Bool? = nil) throws {
        _ = try profile(id: id)
        if let name {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...60).contains(clean.count) else { throw VoiceStoreError.invalidName }
            try run("UPDATE voice_profiles SET name = ? WHERE id = ?", [.text(clean), .text(id)])
        }
        if let faceName {
            let face = faceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            try run("UPDATE voice_profiles SET face_name = ? WHERE id = ?", [face.map { .text($0) } ?? .null, .text(id)])
        }
        if let isChild {
            try run("UPDATE voice_profiles SET is_child = ? WHERE id = ?", [.int(isChild ? 1 : 0), .text(id)])
        }
    }

    /// Records a fresh consent (e.g. after the consent text changed).
    public func renewConsent(id: String, consent: VoiceConsent) throws {
        guard consent.isCurrent else { throw VoiceStoreError.consentRequired }
        _ = try profile(id: id)
        try run("UPDATE voice_profiles SET consent_at = ?, consent_version = ?, consent_language = ? WHERE id = ?",
                [.real(consent.acceptedAt.timeIntervalSince1970), .int(Int64(consent.version)), .text(consent.language), .text(id)])
        try logConsent(profileID: id, action: "renewed", version: consent.version, at: consent.acceptedAt)
    }

    /// "Forget me": deletes the person's embeddings, name, face link, labels
    /// and face evidence. Transcript lines keep only "S1"/"S2". The consent log
    /// keeps a nameless "withdrawn" line (random id + date) as proof of erasure.
    public func forget(profileID: String, at date: Date = Date()) throws {
        let p = try profile(id: profileID)
        try transaction {
            try run("UPDATE speaker_segments SET band = NULL, score = NULL, profile_id = NULL WHERE profile_id = ?", [.text(profileID)])
            if let face = p.faceName {
                try run("DELETE FROM face_voice_evidence WHERE face_name = ? COLLATE NOCASE", [.text(face)])
            }
            try run("DELETE FROM voice_embeddings WHERE profile_id = ?", [.text(profileID)])
            try run("DELETE FROM voice_profiles WHERE id = ?", [.text(profileID)])
            try run("DELETE FROM consent_log WHERE profile_id = ?", [.text(profileID)])
            try logConsent(profileID: profileID, action: "withdrawn", version: nil, at: date)
        }
    }

    public func consentLog(profileID: String) throws -> [String] {
        try query("SELECT action FROM consent_log WHERE profile_id = ? ORDER BY id", [.text(profileID)]) { Self.text($0, 0) ?? "" }
    }

    // MARK: Embeddings

    public struct NewEmbedding: Sendable {
        public var vector: VoiceVector
        public var camera: String?
        public var source: String
        public var eventID: String?
        public var speaker: String?
        public var speechSeconds: Double
        public init(vector: VoiceVector, camera: String?, source: String, eventID: String? = nil,
                    speaker: String? = nil, speechSeconds: Double) {
            self.vector = vector
            self.camera = camera
            self.source = source
            self.eventID = eventID
            self.speaker = speaker
            self.speechSeconds = speechSeconds
        }
    }

    /// Adds samples to a person. Refused without a current consent.
    public func addEmbeddings(profileID: String, _ items: [NewEmbedding], at date: Date = Date()) throws {
        let p = try profile(id: profileID)
        guard p.consent.isCurrent else { throw VoiceStoreError.consentRequired }
        try transaction {
            for item in items {
                try insertEmbedding(profileID: profileID, clusterID: nil, item, at: date)
            }
            if items.contains(where: { $0.source != "auto" }) {
                try run("UPDATE voice_profiles SET enrolled_at = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(profileID)])
            }
            try trimAutoSamples(profileID: profileID)
        }
    }

    /// Every sample of every person with a current consent.
    public func gallery() throws -> [EnrolledVoice] {
        let rows = try query("""
            SELECT e.profile_id, e.camera, e.vector FROM voice_embeddings e
            JOIN voice_profiles p ON p.id = e.profile_id
            WHERE p.consent_version = ?
            """, [.int(Int64(VoiceSettings.consentVersion))]) { s in
            (Self.text(s, 0) ?? "", Self.text(s, 1), Self.blob(s, 2))
        }
        return rows.compactMap { id, camera, blob in
            guard let blob, let vector = try? self.openVector(blob) else { return nil }
            return EnrolledVoice(profileID: id, camera: camera, vector: vector)
        }
    }

    private func insertEmbedding(profileID: String?, clusterID: Int64?, _ item: NewEmbedding, at date: Date) throws {
        try run("""
            INSERT INTO voice_embeddings(profile_id, cluster_id, camera, vector, source, event_id, speaker, speech_seconds, created)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, [profileID.map { .text($0) } ?? .null, clusterID.map { .int($0) } ?? .null,
                  item.camera.map { .text($0) } ?? .null, .blob(try sealer.seal(item.vector.data)),
                  .text(item.source), item.eventID.map { .text($0) } ?? .null, item.speaker.map { .text($0) } ?? .null,
                  .real(item.speechSeconds), .real(date.timeIntervalSince1970)])
    }

    private func trimAutoSamples(profileID: String) throws {
        try run("""
            DELETE FROM voice_embeddings WHERE id IN (
              SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (PARTITION BY IFNULL(camera, '') ORDER BY created DESC, id DESC) AS rank
                FROM voice_embeddings WHERE profile_id = ? AND source = 'auto'
              ) WHERE rank > ?)
            """, [.text(profileID), .int(Int64(Self.maxAutoSamplesPerCamera))])
    }

    private func openVector(_ blob: Data) throws -> VoiceVector {
        guard let v = VoiceVector(data: try sealer.open(blob)) else { throw HearingError.storage("vector") }
        return v
    }

    // MARK: Unknown voices

    public func clusters(includeIgnored: Bool = true) throws -> [UnknownVoiceCluster] {
        var sql = """
            SELECT c.id, c.events, c.speech_seconds, c.first_heard, c.last_heard, c.last_camera, c.state,
                   (SELECT COUNT(*) FROM voice_embeddings e WHERE e.cluster_id = c.id)
            FROM unknown_clusters c
            """
        if !includeIgnored { sql += " WHERE c.state = 'open'" }
        sql += " ORDER BY c.last_heard DESC"
        return try query(sql, []) { s in
            UnknownVoiceCluster(id: sqlite3_column_int64(s, 0), events: Int(sqlite3_column_int64(s, 1)),
                                speechSeconds: sqlite3_column_double(s, 2), firstHeard: Self.date(s, 3),
                                lastHeard: Self.date(s, 4), lastCamera: Self.text(s, 5) ?? "",
                                ignored: Self.text(s, 6) == "ignored", samples: Int(sqlite3_column_int64(s, 7)))
        }
    }

    private func centroids() throws -> [(VoiceClustering.Centroid, ignored: Bool)] {
        let rows = try query("SELECT id, centroid, events, state FROM unknown_clusters", []) { s in
            (sqlite3_column_int64(s, 0), Self.blob(s, 1), Int(sqlite3_column_int64(s, 2)), Self.text(s, 3) == "ignored")
        }
        return rows.compactMap { id, blob, events, ignored in
            guard let blob, let v = try? openVector(blob) else { return nil }
            return (VoiceClustering.Centroid(id: id, vector: v, events: events), ignored)
        }
    }

    /// Files an unnamed voice under the nearest cluster (or a new one) and
    /// keeps a capped set of its samples. Returns the cluster and whether it is ignored.
    public func fileUnknown(_ vector: VoiceVector, speechSeconds: Double, camera: String, eventID: String,
                            speaker: String, threshold: Float, at date: Date = Date()) throws -> (id: Int64, ignored: Bool) {
        let all = try centroids()
        if let hit = VoiceClustering.nearest(vector, in: all.map(\.0), threshold: threshold),
           let found = all.first(where: { $0.0.id == hit.id }) {
            let updated = VoiceClustering.adding(vector, to: found.0.vector, events: found.0.events)
            try transaction {
                try run("""
                    UPDATE unknown_clusters SET centroid = ?, events = events + 1, speech_seconds = speech_seconds + ?,
                    last_heard = MAX(last_heard, ?), last_camera = ? WHERE id = ?
                    """, [.blob(try sealer.seal(updated.data)), .real(speechSeconds), .real(date.timeIntervalSince1970),
                          .text(camera), .int(hit.id)])
                try insertEmbedding(profileID: nil, clusterID: hit.id, .init(vector: vector, camera: camera, source: "unknown",
                                                                            eventID: eventID, speaker: speaker,
                                                                            speechSeconds: speechSeconds), at: date)
                try trimClusterSamples(hit.id)
            }
            return (hit.id, found.ignored)
        }
        var id: Int64 = 0
        try transaction {
            try run("""
                INSERT INTO unknown_clusters(centroid, events, speech_seconds, first_heard, last_heard, last_camera)
                VALUES (?,?,?,?,?,?)
                """, [.blob(try sealer.seal(vector.data)), .int(1), .real(speechSeconds), .real(date.timeIntervalSince1970),
                      .real(date.timeIntervalSince1970), .text(camera)])
            id = sqlite3_last_insert_rowid(db)
            try insertEmbedding(profileID: nil, clusterID: id, .init(vector: vector, camera: camera, source: "unknown",
                                                                    eventID: eventID, speaker: speaker,
                                                                    speechSeconds: speechSeconds), at: date)
        }
        return (id, false)
    }

    private func trimClusterSamples(_ id: Int64) throws {
        try run("""
            DELETE FROM voice_embeddings WHERE cluster_id = ? AND id NOT IN (
              SELECT id FROM voice_embeddings WHERE cluster_id = ? ORDER BY created DESC, id DESC LIMIT ?)
            """, [.int(id), .int(id), .int(Int64(Self.maxClusterSamples))])
    }

    /// Merges `absorb` into `keep` (owner action, or drift found by `consolidate`).
    public func mergeClusters(keep: Int64, absorb: Int64) throws {
        guard keep != absorb else { return }
        let all = try centroids()
        guard let a = all.first(where: { $0.0.id == keep }), let b = all.first(where: { $0.0.id == absorb }) else {
            throw VoiceStoreError.unknownCluster
        }
        let merged = VoiceVector.mean([a.0.vector, b.0.vector], weights: [Float(a.0.events), Float(b.0.events)]) ?? a.0.vector
        try transaction {
            try run("""
                UPDATE unknown_clusters SET centroid = ?,
                  events = events + (SELECT events FROM unknown_clusters WHERE id = ?),
                  speech_seconds = speech_seconds + (SELECT speech_seconds FROM unknown_clusters WHERE id = ?),
                  first_heard = MIN(first_heard, (SELECT first_heard FROM unknown_clusters WHERE id = ?)),
                  last_heard = MAX(last_heard, (SELECT last_heard FROM unknown_clusters WHERE id = ?)),
                  state = CASE WHEN state = 'ignored' OR (SELECT state FROM unknown_clusters WHERE id = ?) = 'ignored'
                               THEN 'ignored' ELSE 'open' END
                WHERE id = ?
                """, [.blob(try sealer.seal(merged.data)), .int(absorb), .int(absorb), .int(absorb), .int(absorb),
                      .int(absorb), .int(keep)])
            try run("UPDATE voice_embeddings SET cluster_id = ? WHERE cluster_id = ?", [.int(keep), .int(absorb)])
            try run("UPDATE speaker_segments SET cluster_id = ? WHERE cluster_id = ?", [.int(keep), .int(absorb)])
            try run("INSERT OR IGNORE INTO face_voice_evidence(cluster_id, face_name, event_id, at) SELECT ?, face_name, event_id, at FROM face_voice_evidence WHERE cluster_id = ?",
                    [.int(keep), .int(absorb)])
            try run("DELETE FROM unknown_clusters WHERE id = ?", [.int(absorb)])
            try trimClusterSamples(keep)
        }
    }

    /// Merges clusters whose centroids now sit closer than `threshold`. Returns merges done.
    @discardableResult
    public func consolidate(threshold: Float) throws -> Int {
        let plan = VoiceClustering.mergePlan(try centroids().map(\.0), threshold: threshold)
        for step in plan { try mergeClusters(keep: step.keep, absorb: step.absorb) }
        return plan.count
    }

    /// "This is the TV" / ignore: future matches are labelled ignored, never suggested.
    public func setIgnored(clusterID: Int64, _ ignored: Bool) throws {
        try run("UPDATE unknown_clusters SET state = ? WHERE id = ?", [.text(ignored ? "ignored" : "open"), .int(clusterID)])
        try run("UPDATE speaker_segments SET band = ? WHERE cluster_id = ?", [.text(ignored ? VoiceBand.ignored.rawValue : VoiceBand.unknown.rawValue), .int(clusterID)])
    }

    public func forgetCluster(_ clusterID: Int64) throws {
        try transaction {
            try run("UPDATE speaker_segments SET band = NULL, score = NULL, cluster_id = NULL WHERE cluster_id = ?", [.int(clusterID)])
            try run("DELETE FROM unknown_clusters WHERE id = ?", [.int(clusterID)])
        }
    }

    /// Names a cluster: its samples become the person's (consent required),
    /// past lines get the name, and the cluster goes away.
    public func assignCluster(_ clusterID: Int64, to profileID: String, at date: Date = Date()) throws {
        let p = try profile(id: profileID)
        guard p.consent.isCurrent else { throw VoiceStoreError.consentRequired }
        guard try clusters().contains(where: { $0.id == clusterID }) else { throw VoiceStoreError.unknownCluster }
        try transaction {
            try run("UPDATE voice_embeddings SET profile_id = ?, cluster_id = NULL, source = 'cluster' WHERE cluster_id = ?",
                    [.text(profileID), .int(clusterID)])
            try run("UPDATE speaker_segments SET profile_id = ?, cluster_id = NULL, band = ? WHERE cluster_id = ?",
                    [.text(profileID), .text(VoiceBand.confirmed.rawValue), .int(clusterID)])
            try run("DELETE FROM unknown_clusters WHERE id = ?", [.int(clusterID)])
            try run("UPDATE voice_profiles SET enrolled_at = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(profileID)])
        }
    }

    // MARK: Face ↔ voice

    public func addFaceEvidence(clusterID: Int64, face: String, eventID: String, at date: Date = Date()) throws {
        try run("INSERT OR IGNORE INTO face_voice_evidence(cluster_id, face_name, event_id, at) VALUES (?,?,?,?)",
                [.int(clusterID), .text(face), .text(eventID), .real(date.timeIntervalSince1970)])
    }

    /// "Not this person": drops the face evidence of one cluster.
    public func clearFaceEvidence(clusterID: Int64) throws {
        try run("DELETE FROM face_voice_evidence WHERE cluster_id = ?", [.int(clusterID)])
    }

    public func faceCounts(clusterID: Int64) throws -> [String: Int] {
        let rows = try query("SELECT face_name, COUNT(*) FROM face_voice_evidence WHERE cluster_id = ? GROUP BY face_name",
                             [.int(clusterID)]) { (Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1))) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// Open (not ignored) clusters with a face suggestion.
    public func faceSuggestions() throws -> [FaceVoiceSuggestion] {
        try clusters(includeIgnored: false).compactMap { cluster in
            switch FaceVoiceRule.decision(counts: try faceCounts(clusterID: cluster.id)) {
            case .none: return nil
            case .suggest(let face, let n): return FaceVoiceSuggestion(clusterID: cluster.id, face: face, agreeing: n)
            case .promote(let face):
                return FaceVoiceSuggestion(clusterID: cluster.id, face: face,
                                           agreeing: try faceCounts(clusterID: cluster.id)[face] ?? 0)
            }
        }
    }

    /// Auto-promotes a cluster after `FaceVoiceRule.promotionCount` agreeing
    /// events, but only into an adult profile that already has a current
    /// consent and this face name. Returns the profile when promoted.
    @discardableResult
    public func promoteIfReady(clusterID: Int64, at date: Date = Date()) throws -> VoiceProfile? {
        guard case .promote(let face) = FaceVoiceRule.decision(counts: try faceCounts(clusterID: clusterID)),
              try clusters(includeIgnored: false).contains(where: { $0.id == clusterID }) else { return nil }
        let matches = try profiles().filter {
            $0.faceName?.compare(face, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard matches.count == 1, let target = matches.first, !target.isChild, target.consent.isCurrent else { return nil }
        try assignCluster(clusterID, to: target.id, at: date)
        try run("UPDATE voice_embeddings SET source = 'face_link' WHERE profile_id = ? AND source = 'cluster'", [.text(target.id)])
        return try profile(id: target.id)
    }

    // MARK: Events

    /// Replaces the speaker rows of one event. Turn times are clip time.
    public func recordEvent(eventID: String, camera: String, eventStart: Date, turns: [SpeakerTurn],
                            assignments: [SpeakerAssignment], at date: Date = Date()) throws {
        let byLabel = Dictionary(assignments.map { ($0.speaker, $0) }, uniquingKeysWith: { a, _ in a })
        try transaction {
            try run("DELETE FROM speaker_segments WHERE event_id = ?", [.text(eventID)])
            for turn in turns {
                let a = byLabel[turn.speaker]
                try run("""
                    INSERT INTO speaker_segments(event_id, camera, event_start, speaker, start, end, created,
                                                 profile_id, cluster_id, band, score)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(eventID), .text(camera), .real(eventStart.timeIntervalSince1970), .text(turn.speaker),
                          .real(turn.start), .real(turn.end), .real(date.timeIntervalSince1970),
                          a?.profileID.map { .text($0) } ?? .null, a?.clusterID.map { .int($0) } ?? .null,
                          a?.band.map { .text($0.rawValue) } ?? .null, a?.score.map { .real(Double($0)) } ?? .null])
            }
        }
    }

    public func turns(eventID: String, speaker: String? = nil) throws -> [SpeakerTurn] {
        var sql = "SELECT speaker, start, end FROM speaker_segments WHERE event_id = ?"
        var args: [Value] = [.text(eventID)]
        if let speaker { sql += " AND speaker = ?"; args.append(.text(speaker)) }
        return try query(sql + " ORDER BY start", args) {
            SpeakerTurn(speaker: Self.text($0, 0) ?? "", start: sqlite3_column_double($0, 1), end: sqlite3_column_double($0, 2))
        }
    }

    /// Speaker labels for the transcripts list: event id → speaker → display.
    public func labels(eventIDs: [String]) throws -> [String: [String: SpeakerDisplay]] {
        guard !eventIDs.isEmpty else { return [:] }
        var out: [String: [String: SpeakerDisplay]] = [:]
        for chunk in stride(from: 0, to: eventIDs.count, by: 400).map({ Array(eventIDs[$0..<min($0 + 400, eventIDs.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try query("""
                SELECT DISTINCT s.event_id, s.speaker, s.band, s.profile_id, p.name, s.cluster_id
                FROM speaker_segments s LEFT JOIN voice_profiles p ON p.id = s.profile_id
                WHERE s.event_id IN (\(marks))
                """, chunk.map { .text($0) }) { s in
                (Self.text(s, 0) ?? "", SpeakerDisplay(
                    speaker: Self.text(s, 1) ?? "", band: Self.text(s, 2).flatMap(VoiceBand.init(rawValue:)),
                    profileID: Self.text(s, 3), name: Self.text(s, 4),
                    clusterID: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 5)))
            }
            for (event, display) in rows { out[event, default: [:]][display.speaker] = display }
        }
        return out
    }

    // MARK: Retention

    /// Drops speaker rows of events before `cutoff` and unknown voices not
    /// heard since. Named people stay until "forget me".
    @discardableResult
    public func purge(olderThan cutoff: Date) throws -> Int {
        let t = cutoff.timeIntervalSince1970
        var removed = 0
        try transaction {
            try run("DELETE FROM speaker_segments WHERE event_start < ?", [.real(t)])
            removed = Int(sqlite3_changes(db))
            try run("DELETE FROM unknown_clusters WHERE last_heard < ?", [.real(t)])
            try run("DELETE FROM face_voice_evidence WHERE at < ?", [.real(t)])
        }
        return removed
    }

    /// Everything: people, samples, unknown voices, labels.
    public func deleteAll() throws {
        try Self.exec(db, """
            DELETE FROM face_voice_evidence; DELETE FROM speaker_segments; DELETE FROM voice_embeddings;
            DELETE FROM unknown_clusters; DELETE FROM voice_profiles; DELETE FROM consent_log; VACUUM;
            """)
    }

    public func embeddingCount() throws -> Int {
        try query("SELECT COUNT(*) FROM voice_embeddings", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    // MARK: SQLite plumbing

    private func logConsent(profileID: String, action: String, version: Int?, at date: Date) throws {
        try run("INSERT INTO consent_log(profile_id, action, consent_version, at) VALUES (?,?,?,?)",
                [.text(profileID), .text(action), version.map { .int(Int64($0)) } ?? .null, .real(date.timeIntervalSince1970)])
    }

    private static let profileSelect = """
        SELECT p.id, p.name, p.face_name, p.is_child, p.consent_at, p.consent_version, p.consent_language, p.created,
               p.enrolled_at, (SELECT COUNT(*) FROM voice_embeddings e WHERE e.profile_id = p.id)
        FROM voice_profiles p
        """

    private static func profileRow(_ s: OpaquePointer) -> VoiceProfile {
        VoiceProfile(id: text(s, 0) ?? "", name: text(s, 1) ?? "", faceName: text(s, 2), isChild: sqlite3_column_int(s, 3) != 0,
                     consent: VoiceConsent(acceptedAt: date(s, 4), version: Int(sqlite3_column_int(s, 5)), language: text(s, 6) ?? ""),
                     created: date(s, 7),
                     enrolledAt: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : date(s, 8),
                     sampleCount: Int(sqlite3_column_int64(s, 9)))
    }

    private enum Value { case text(String), real(Double), int(Int64), blob(Data), null }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
    private static func date(_ s: OpaquePointer, _ i: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(s, i)) }
    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, i)))
    }

    private var transactionDepth = 0
    private func transaction(_ body: () throws -> Void) throws {
        if transactionDepth > 0 { try body(); return }
        try Self.exec(db, "BEGIN IMMEDIATE;")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            try body()
            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HearingError.storage(message)
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HearingError.storage(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .int(let i): sqlite3_bind_int64(statement, index, i)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(d.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ args: [Value]) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw HearingError.storage(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ args: [Value], _ row: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW { out.append(try row(statement)); continue }
            guard rc == SQLITE_DONE else { throw HearingError.storage(String(cString: sqlite3_errmsg(db))) }
            return out
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
