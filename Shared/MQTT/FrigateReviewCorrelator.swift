import Foundation

/// Review-first notification authority shared by the macOS and tvOS Bridge.
/// Raw tracker events are cached as evidence and never emitted as a user-visible
/// notification until a Frigate Review Item references them.
nonisolated struct FrigateReviewCorrelator {
    struct Review: Equatable {
        let id: String
        let severity: String
        let camera: String?
        let startTime: Date?
        let detectionIDs: [String]
    }

    private var events: [String: FrigateMQTTClient.Event] = [:]
    private var eventOrder: [String] = []
    private var pending: [Review] = []
    private(set) var claimedKeys: Set<String>
    private var claimOrder: [String]
    private var inFlightKeys: Set<String> = []

    private let maxAge: TimeInterval
    private let futureSkew: TimeInterval

    init(
        maxAge: TimeInterval = 120,
        futureSkew: TimeInterval = 30,
        restoredClaims: [String] = []
    ) {
        self.maxAge = maxAge
        self.futureSkew = futureSkew
        self.claimedKeys = Set(restoredClaims)
        self.claimOrder = Array(restoredClaims.suffix(4_096))
    }

    mutating func ingest(event: FrigateMQTTClient.Event, now: Date = Date()) -> [FrigateMQTTClient.Event] {
        guard event.kind == .new, isFresh(event.startTime, now: now) else { return [] }
        events[event.id] = event
        eventOrder.removeAll { $0 == event.id }
        eventOrder.append(event.id)
        trimEvents()

        var resolved: [FrigateMQTTClient.Event] = []
        let previousPending = pending
        pending.removeAll(keepingCapacity: true)
        for review in previousPending {
            guard review.detectionIDs.contains(event.id) else {
                pending.append(review)
                continue
            }
            if let output = resolve(review: review, now: now) {
                resolved.append(output)
            } else {
                pending.append(review)
            }
        }
        expire(now: now)
        return resolved
    }

    mutating func ingest(review: Review, now: Date = Date()) -> [FrigateMQTTClient.Event] {
        guard validate(review: review, now: now) else { return [] }
        if let output = resolve(review: review, now: now) {
            return [output]
        }
        pending.removeAll { $0.id == review.id }
        pending.append(review)
        if pending.count > 256 { pending.removeFirst(pending.count - 256) }
        expire(now: now)
        return []
    }

    private mutating func resolve(review: Review, now: Date) -> FrigateMQTTClient.Event? {
        let claim = "\(review.id)/\(review.severity)"
        guard !claimedKeys.contains(claim), !inFlightKeys.contains(claim) else { return nil }
        let candidates = review.detectionIDs.compactMap { events[$0] }.filter { isFresh($0.startTime, now: now) }
        guard let event = candidates.max(by: {
            if $0.topScore == $1.topScore { return $0.id < $1.id }
            return $0.topScore < $1.topScore
        }) else { return nil }
        if let camera = review.camera, !camera.isEmpty, camera != event.camera { return nil }
        if let reviewStart = review.startTime,
           event.startTime.addingTimeInterval(futureSkew) < reviewStart { return nil }

        inFlightKeys.insert(claim)
        return event.withReview(id: review.id, severity: review.severity)
    }

    mutating func complete(event: FrigateMQTTClient.Event, terminal: Bool) {
        guard let reviewID = event.reviewID, let severity = event.reviewSeverity else { return }
        let claim = "\(reviewID)/\(severity)"
        inFlightKeys.remove(claim)
        guard terminal else { return }
        claimedKeys.insert(claim)
        claimOrder.removeAll { $0 == claim }
        claimOrder.append(claim)
        if claimOrder.count > 4_096 {
            for old in claimOrder.prefix(claimOrder.count - 4_096) { claimedKeys.remove(old) }
            claimOrder.removeFirst(claimOrder.count - 4_096)
        }
    }

    private func validate(review: Review, now: Date) -> Bool {
        guard !review.id.isEmpty,
              review.severity == "alert" || review.severity == "detection",
              !review.detectionIDs.isEmpty else { return false }
        if let start = review.startTime, !isFresh(start, now: now) { return false }
        return true
    }

    private func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -futureSkew && age <= maxAge
    }

    private mutating func trimEvents() {
        while eventOrder.count > 2_048 {
            events.removeValue(forKey: eventOrder.removeFirst())
        }
    }

    private mutating func expire(now: Date) {
        let previousOrder = eventOrder
        eventOrder.removeAll(keepingCapacity: true)
        for id in previousOrder {
            guard let event = events[id] else { continue }
            if !isFresh(event.startTime, now: now) {
                events.removeValue(forKey: id)
            } else {
                eventOrder.append(id)
            }
        }
        let previousPending = pending
        pending = previousPending.filter { review in
            guard let start = review.startTime else { return true }
            return isFresh(start, now: now)
        }
    }
}
