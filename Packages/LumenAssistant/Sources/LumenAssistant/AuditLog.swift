import CryptoKit
import Foundation

/// One line of the assistant's audit log. Only accepted commands keep their
/// words (`command`); refusals keep the action and reason, never the sentence.
/// Nothing else heard is ever written.
public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case executed, previewed, answered, proposed, refused, failed, undone, confirmed
    }

    public var seq: Int
    public var date: Date
    public var outcome: Outcome
    public var camera: String
    public var mode: AssistantMode
    public var speaker: String
    public var action: DeviceAction
    public var targets: [String]
    public var tier: ActionTier
    public var source: CommandSource
    /// The accepted command text (normalized). Nil for refusals.
    public var command: String?
    public var reason: String?
    /// Utterance end → action sent, in milliseconds.
    public var latencyMs: Int?
    /// For undo: the `seq` this entry reverses.
    public var reverses: Int?
    public var prevHash: String
    public var hash: String

    public var id: Int { seq }

    /// SHA-256 over the previous hash and the entry's canonical JSON (without its own hash).
    func computedHash() -> String {
        var copy = self
        copy.hash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let body = (try? encoder.encode(copy)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: Data(prevHash.utf8))
        hasher.update(data: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum AuditError: Error, Equatable, Sendable {
    case brokenChain(seq: Int)
    case io
}

/// Append-only, hash-chained JSON-lines log on this Mac (file 0600, excluded
/// from backups). Pruning keeps the chain checkable: the first kept entry's
/// `prevHash` is written to an anchor file.
public actor AuditLog {
    public static let genesis = String(repeating: "0", count: 64)
    private let url: URL
    private var anchorURL: URL { url.appendingPathExtension("anchor") }
    private var entries: [AuditEntry] = []

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            entries = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(AuditEntry.self, from: Data($0)) }
        } else {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    public var all: [AuditEntry] { entries }
    public func last(_ n: Int) -> [AuditEntry] { Array(entries.suffix(n).reversed()) }

    @discardableResult
    public func append(outcome: AuditEntry.Outcome, camera: String, mode: AssistantMode, speaker: String, plan: ActionPlan,
                       source: CommandSource, command: String?, reason: String? = nil, latencyMs: Int? = nil,
                       reverses: Int? = nil, at date: Date = Date()) throws -> AuditEntry {
        let prev = entries.last?.hash ?? anchor()
        // Whole milliseconds, so the JSON round-trip is exact and the hash re-checks from disk.
        let stamp = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
        var entry = AuditEntry(seq: (entries.last?.seq ?? 0) + 1, date: stamp, outcome: outcome, camera: camera, mode: mode,
                               speaker: speaker, action: plan.action, targets: plan.targets.map(\.entityID), tier: plan.tier,
                               source: source, command: outcome == .refused ? nil : command, reason: reason,
                               latencyMs: latencyMs, reverses: reverses, prevHash: prev, hash: "")
        entry.hash = entry.computedHash()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard var line = try? encoder.encode(entry) else { throw AuditError.io }
        line.append(UInt8(ascii: "\n"))
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch { throw AuditError.io }
        entries.append(entry)
        return entry
    }

    /// Walks the chain; throws at the first entry whose hash or link is wrong.
    public func verify() throws {
        try Self.verify(entries, anchor: anchor())
    }

    public static func verify(_ entries: [AuditEntry], anchor: String) throws {
        var prev = anchor
        for entry in entries {
            guard entry.prevHash == prev, entry.computedHash() == entry.hash else { throw AuditError.brokenChain(seq: entry.seq) }
            prev = entry.hash
        }
    }

    /// Re-reads the file from disk and verifies it (detects edits made outside the app).
    public func verifyOnDisk() throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var onDisk: [AuditEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(AuditEntry.self, from: Data(line)) else {
                throw AuditError.brokenChain(seq: (onDisk.last?.seq ?? 0) + 1)
            }
            onDisk.append(entry)
        }
        try Self.verify(onDisk, anchor: anchor())
    }

    /// Drops entries older than `cutoff`, keeping the chain checkable.
    @discardableResult
    public func purge(olderThan cutoff: Date) throws -> Int {
        let kept = entries.filter { $0.date >= cutoff }
        let removed = entries.count - kept.count
        guard removed > 0 else { return 0 }
        let anchorHash = kept.first?.prevHash ?? entries.last?.hash ?? Self.genesis
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = Data()
        for entry in kept {
            guard let line = try? encoder.encode(entry) else { throw AuditError.io }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        do {
            try Data(anchorHash.utf8).write(to: anchorURL, options: .atomic)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw AuditError.io }
        entries = kept
        return removed
    }

    public func deleteAll() throws {
        do {
            try Data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: anchorURL)
        } catch { throw AuditError.io }
        entries = []
    }

    private func anchor() -> String {
        guard let data = try? Data(contentsOf: anchorURL), let text = String(data: data, encoding: .utf8),
              text.count == 64 else { return Self.genesis }
        return text
    }
}
