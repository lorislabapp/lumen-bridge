import CoreGraphics
import Foundation

/// Areas, learned looks, recent results and proof frames, on this Mac only.
/// Layout: `targets.json`, `results.json`, `references/<uuid>.jpg`, `proofs/<uuid>.jpg`.
/// Proofs are short-lived (default 24 h) and never leave the Hub by push.
public actor LookStore {
    public let root: URL
    private var targets: [String: LookTarget] = [:]
    private var results: [LookResult] = []
    private var referenceCache: [String: CGImageBox] = [:]
    public var proofRetention: TimeInterval
    public static let maxResults = 200
    public static let maxProofs = 300

    public init(root: URL, proofRetention: TimeInterval = 24 * 3600) {
        self.root = root
        self.proofRetention = proofRetention
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("proofs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let data = try? Data(contentsOf: root.appendingPathComponent("targets.json")),
           let list = try? decoder.decode([LookTarget].self, from: data) {
            targets = Dictionary(list.map { ($0.entityID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("results.json")),
           let list = try? decoder.decode([LookResult].self, from: data) {
            results = list
        }
    }

    // MARK: Targets

    public var allTargets: [LookTarget] { targets.values.sorted { $0.name < $1.name } }
    public func target(_ entityID: String) -> LookTarget? { targets[entityID] }

    public func upsert(_ target: LookTarget) {
        if let old = targets[target.entityID], old.camera != target.camera || old.area != target.area {
            // New area or camera: learned looks no longer apply.
            var fresh = target
            if old.camera != target.camera || !Self.close(old.area, target.area) { fresh.samples = [:] }
            targets[target.entityID] = fresh
        } else {
            targets[target.entityID] = target
        }
        saveTargets()
    }

    public func remove(_ entityID: String) {
        if let file = targets[entityID]?.referenceFile { try? FileManager.default.removeItem(at: referenceURL(file)) }
        targets[entityID] = nil
        saveTargets()
    }

    /// Saves the whole frame (≤ 640 px) the area was drawn on, for the camera-moved check.
    public func setReference(_ entityID: String, image: CGImage, at date: Date = Date()) {
        guard var t = targets[entityID], let small = image.scaled(maxSide: 640), let data = JPEG.encode(small, quality: 0.8) else { return }
        if let old = t.referenceFile { try? FileManager.default.removeItem(at: referenceURL(old)) }
        let name = UUID().uuidString + ".jpg"
        guard (try? data.write(to: referenceURL(name), options: .atomic)) != nil else { return }
        t.referenceFile = name
        t.referenceTakenAt = date
        targets[entityID] = t
        referenceCache[entityID] = CGImageBox(image: small, file: name)
        saveTargets()
    }

    public func reference(for entityID: String) -> CGImage? {
        guard let file = targets[entityID]?.referenceFile else { return nil }
        if let cached = referenceCache[entityID], cached.file == file { return cached.image }
        guard let data = try? Data(contentsOf: referenceURL(file)), let image = JPEG.decode(data) else { return nil }
        referenceCache[entityID] = CGImageBox(image: image, file: file)
        return image
    }

    public func learn(_ entityID: String, state: LookState, infrared: Bool, features: ROIFeatures, at date: Date = Date()) {
        guard var t = targets[entityID] else { return }
        t.samples[StateSample.key(state, infrared: infrared)] = StateSample(features: features, learnedAt: date)
        targets[entityID] = t
        saveTargets()
    }

    // MARK: Results and proofs

    public func record(_ result: LookResult) {
        results.insert(result, at: 0)
        if results.count > Self.maxResults { results.removeLast(results.count - Self.maxResults) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(results) { try? data.write(to: root.appendingPathComponent("results.json"), options: .atomic) }
    }

    public func recent(_ limit: Int = 50) -> [LookResult] { Array(results.prefix(limit)) }
    public func last(for entityID: String) -> LookResult? { results.first { $0.entityID == entityID } }

    /// Cropped proof JPEG. Returns the file name (not a path).
    public func saveProof(_ image: CGImage) -> String? {
        guard let small = image.scaled(maxSide: 640), let data = JPEG.encode(small, quality: 0.7) else { return nil }
        let name = UUID().uuidString + ".jpg"
        guard (try? data.write(to: proofURL(name), options: [.atomic, .completeFileProtection])) != nil else { return nil }
        prune()
        return name
    }

    /// Proof bytes for the UI or a later authenticated fetch by the iPhone app.
    public func proof(_ name: String) -> Data? {
        guard Self.safeName(name) else { return nil }
        return try? Data(contentsOf: proofURL(name))
    }

    /// Deletes proofs past retention, and the oldest beyond the cap.
    public func prune(now: Date = Date()) {
        let dir = root.appendingPathComponent("proofs")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let d = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
            return (url, d)
        }.sorted { $0.1 > $1.1 }
        for (i, (url, date)) in dated.enumerated() where now.timeIntervalSince(date) > proofRetention || i >= Self.maxProofs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func setRetention(_ seconds: TimeInterval) {
        proofRetention = max(3600, seconds)
        prune()
    }

    // MARK: Files

    private func saveTargets() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(allTargets) {
            try? data.write(to: root.appendingPathComponent("targets.json"), options: .atomic)
        }
    }

    private func referenceURL(_ name: String) -> URL { root.appendingPathComponent("references").appendingPathComponent(name) }
    private func proofURL(_ name: String) -> URL { root.appendingPathComponent("proofs").appendingPathComponent(name) }

    static func safeName(_ name: String) -> Bool {
        name.count <= 64 && name.hasSuffix(".jpg") && !name.contains("/") && !name.contains("..")
    }

    static func close(_ a: LookRect, _ b: LookRect) -> Bool {
        abs(a.x - b.x) < 0.02 && abs(a.y - b.y) < 0.02 && abs(a.width - b.width) < 0.02 && abs(a.height - b.height) < 0.02
    }
}

struct CGImageBox: @unchecked Sendable {
    let image: CGImage
    let file: String
}
