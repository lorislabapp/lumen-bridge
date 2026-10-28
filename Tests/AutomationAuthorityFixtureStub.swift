import Foundation

enum FrigateMQTTClient {
    struct Event: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case new, end }
        let id: String
        let camera: String
        let label: String
        let zones: [String]
        let topScore: Double
        let startTime: Date
        let kind: Kind
        let subLabel: String?
        let stationary: Bool?
        let hasClip: Bool
        let recognizedPlate: String?
        let reviewID: String?
        let reviewSeverity: String?
    }
}

final class MemoryKVS: NSUbiquitousKeyValueStore {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func longLong(forKey key: String) -> Int64 {
        if let value = values[key] as? Int64 { return value }
        if let value = values[key] as? NSNumber { return value.int64Value }
        return 0
    }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func synchronize() -> Bool { true }
}
