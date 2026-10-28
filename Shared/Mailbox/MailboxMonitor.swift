import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "MailboxMonitor")

/// 24/7 mailbox visit detection for the Hub.
///
/// Designed from the owner's real passes (front camera, 12–19 Oct 2026):
/// visitors stay 0.4–10 s in the mailbox zone, Frigate often loses them
/// right after ("gone") instead of seeing them walk to another zone, one
/// visit can be split into several tracked objects a few minutes apart,
/// and about half of the passes are household members recognised by face.
///
/// So a visit is: a person on the configured camera whose event touched the
/// mailbox zone, reported when Frigate closes that event, unless a
/// recognised household member was there at the same time. Pieces close in
/// time are grouped into one visit. Never claims "postman" or "mail".
@MainActor
final class MailboxMonitor {
    struct Configuration: Codable, Sendable, Equatable {
        var camera: String
        var mailboxZone: String
        /// Events ending within this many seconds of the previous visit are
        /// the same visit (split tracks, someone coming back for a parcel).
        var groupWindowSeconds: Double = 300
        /// A recognised person on the camera this close in time means a
        /// household member is there: no alert.
        var residentWindowSeconds: Double = 60
        /// Names that count as household. Empty = any recognised face.
        var residentNames: [String] = []
        /// Frigate labels that count (person, car, dog…). Default: person.
        var labels: [String] = ["person"]
        /// Ignore objects Frigate recognises (faces, known plates…) and stay
        /// silent while one is there. Off = everyone counts.
        var ignoreRecognized: Bool = true

        init(camera: String, mailboxZone: String, labels: [String] = ["person"], ignoreRecognized: Bool = true) {
            self.camera = camera
            self.mailboxZone = mailboxZone
            self.labels = labels
            self.ignoreRecognized = ignoreRecognized
        }

        /// Older saved configurations have no labels / ignoreRecognized.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            camera = try c.decode(String.self, forKey: .camera)
            mailboxZone = try c.decode(String.self, forKey: .mailboxZone)
            groupWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .groupWindowSeconds) ?? 300
            residentWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .residentWindowSeconds) ?? 60
            residentNames = try c.decodeIfPresent([String].self, forKey: .residentNames) ?? []
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? ["person"]
            ignoreRecognized = try c.decodeIfPresent(Bool.self, forKey: .ignoreRecognized) ?? true
        }

        var isValid: Bool {
            !camera.isEmpty && !mailboxZone.isEmpty && !labels.isEmpty
                && groupWindowSeconds.isFinite && (0...3600).contains(groupWindowSeconds)
                && residentWindowSeconds.isFinite && (0...600).contains(residentWindowSeconds)
        }
    }

    struct Visit: Sendable, Equatable {
        let eventIDs: [String]
        let camera: String
        let start: Date
        let end: Date
        /// Frigate label that triggered the visit (person, car…).
        var label: String = "person"
    }

    private struct Track {
        var start: Double
        var end: Double?
        var touchedMailbox = false
        var resident = false
        var reported = false
    }

    private(set) var configuration: Configuration?
    private var tracks: [String: Track] = [:]
    private var lastVisitEnd: Double?
    private static let maximumTracks = 512

    var onVisit: (@MainActor (Visit) -> Void)?

    init() {}

    var isActive: Bool { configuration != nil }

    /// Applies (or clears) the owner's configuration. Any change forgets
    /// half-observed events from the old configuration.
    func configure(_ configuration: Configuration?) {
        guard configuration != self.configuration else { return }
        if let configuration, !configuration.isValid {
            logger.error("invalid mailbox configuration ignored")
            self.configuration = nil
        } else {
            self.configuration = configuration
        }
        tracks.removeAll()
        lastVisitEnd = nil
    }

    /// MQTT reconnect: events in flight may have missed their end message.
    func connectionChanged(connected: Bool) {
        tracks.removeAll()
    }

    func consume(_ observation: MailboxObservation) {
        guard let configuration, observation.camera == configuration.camera, !observation.falsePositive else { return }
        // Recognised household members (faces) are tracked whatever the
        // alert's labels, so a resident nearby silences e.g. a car alert too.
        let counts = configuration.labels.contains(observation.label)
        guard counts || (configuration.ignoreRecognized && observation.label == "person" && observation.subLabel != nil)
        else { return }

        var track = tracks[observation.id] ?? Track(start: observation.startTime)
        if tracks[observation.id] == nil {
            guard tracks.count < Self.maximumTracks else {
                logger.warning("mailbox monitor track limit reached; event ignored")
                return
            }
        }
        if observation.zones.contains(configuration.mailboxZone) { track.touchedMailbox = true }
        if configuration.ignoreRecognized, let name = observation.subLabel,
           configuration.residentNames.isEmpty || configuration.residentNames.contains(name) {
            track.resident = true
        }
        if let end = observation.endTime { track.end = end }
        tracks[observation.id] = track

        guard counts, observation.isFinished, track.touchedMailbox, !track.resident, !track.reported else {
            pruneFinished(before: observation.startTime - 3600)
            return
        }
        let end = track.end ?? observation.startTime
        tracks[observation.id]?.reported = true
        guard !residentPresent(around: track.start, end: end, excluding: observation.id) else { return }

        if let lastVisitEnd, track.start - lastVisitEnd <= configuration.groupWindowSeconds {
            self.lastVisitEnd = max(lastVisitEnd, end)
            return
        }
        lastVisitEnd = end
        let visit = Visit(eventIDs: [observation.id], camera: observation.camera,
                          start: Date(timeIntervalSince1970: track.start),
                          end: Date(timeIntervalSince1970: end), label: observation.label)
        logger.info("mailbox visit for event \(observation.id, privacy: .public)")
        onVisit?(visit)
    }

    private func residentPresent(around start: Double, end: Double, excluding id: String) -> Bool {
        guard let window = configuration?.residentWindowSeconds else { return false }
        return tracks.contains { key, other in
            guard key != id, other.resident else { return false }
            let otherEnd = other.end ?? .infinity
            return other.start <= end + window && otherEnd >= start - window
        }
    }

    private func pruneFinished(before time: Double) {
        tracks = tracks.filter { _, track in (track.end ?? .infinity) >= time }
    }
}
