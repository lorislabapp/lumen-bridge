import Foundation

/// What the mailbox detector needs from one `frigate/events` MQTT message.
/// Decoded independently from the notification event model so `update`
/// messages (where faces get recognised) are not lost.
struct MailboxObservation: Sendable, Equatable {
    enum Kind: String, Sendable { case new, update, end }

    let id: String
    let camera: String
    let label: String
    let kind: Kind
    /// Every zone the object has been in so far (entered ∪ current).
    let zones: [String]
    /// Frigate sub label (recognised face or custom classification), if any.
    let subLabel: String?
    let startTime: Double
    let endTime: Double?
    let falsePositive: Bool

    var isFinished: Bool { kind == .end || endTime != nil }

    static func decode(from data: Data) -> MailboxObservation? {
        struct Wire: Decodable {
            let type: String
            let after: Inner?
            struct Inner: Decodable {
                let id: String
                let camera: String
                let label: String
                let current_zones: [String]?
                let entered_zones: [String]?
                let sub_label: FlexibleSubLabel?
                let start_time: Double
                let end_time: Double?
                let false_positive: Bool?
            }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let kind = Kind(rawValue: wire.type), let a = wire.after,
              !a.id.isEmpty, a.id.utf8.count <= 256, !a.camera.isEmpty, a.camera.utf8.count <= 256,
              a.start_time.isFinite, a.end_time?.isFinite ?? true else { return nil }
        var seen = Set<String>()
        let zones = ((a.entered_zones ?? []) + (a.current_zones ?? [])).filter { seen.insert($0).inserted }
        guard zones.count <= 64 else { return nil }
        let subLabel = a.sub_label?.name.flatMap { $0.isEmpty ? nil : $0 }
        return MailboxObservation(id: a.id, camera: a.camera, label: a.label, kind: kind, zones: zones,
                                  subLabel: subLabel, startTime: a.start_time, endTime: a.end_time,
                                  falsePositive: a.false_positive ?? false)
    }
}
