import Foundation

/// Lists Frigate `speech` events (GET /api/events?label=speech&after=…).
public protocol SpeechEventFeed: Sendable {
    func speechEvents(after: Date, limit: Int) async throws -> [SpeechEvent]
}

/// Feeds the pipeline from two sources: MQTT `end` events the Hub already
/// receives (instant), and a REST poll that catches anything MQTT missed.
/// It never backfills history: the cursor starts at "now" the first time,
/// and the pipeline refuses events older than a camera's consent.
public actor SpeechEventIngestor {
    public struct Configuration: Sendable {
        public var interval: Duration = .seconds(90)
        /// Frigate finalises the clip a little after the event ends.
        public var settleDelay: TimeInterval = 20
        /// Re-reads this much history each poll; duplicates are ignored.
        public var overlap: TimeInterval = 30 * 60
        public var pageSize = 50
        public init() {}
    }

    private let feed: any SpeechEventFeed
    private let pipeline: HearingPipeline
    private let loadCursor: @Sendable () -> Date?
    private let saveCursor: @Sendable (Date) -> Void
    private let now: @Sendable () -> Date
    private let config: Configuration
    private var loop: Task<Void, Never>?
    private var delayed: [String: Task<Void, Never>] = [:]
    public private(set) var lastPollError: String?

    public init(feed: any SpeechEventFeed, pipeline: HearingPipeline,
                loadCursor: @escaping @Sendable () -> Date?, saveCursor: @escaping @Sendable (Date) -> Void,
                now: @escaping @Sendable () -> Date = { Date() }, configuration: Configuration = Configuration()) {
        self.feed = feed
        self.pipeline = pipeline
        self.loadCursor = loadCursor
        self.saveCursor = saveCursor
        self.now = now
        self.config = configuration
    }

    public func start() {
        guard loop == nil else { return }
        primeCursor()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: self?.config.interval ?? .seconds(90))
            }
        }
    }

    /// First run starts at "now": history from before the feature was on is never read.
    public func primeCursor() {
        if loadCursor() == nil { saveCursor(now()) }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        delayed.values.forEach { $0.cancel() }
        delayed.removeAll()
    }

    /// One REST pass. Internal visibility for tests.
    @discardableResult
    public func pollOnce() async -> [HearingPipeline.EnqueueResult] {
        let cursor = loadCursor() ?? now()
        let events: [SpeechEvent]
        do {
            events = try await feed.speechEvents(after: cursor.addingTimeInterval(-config.overlap), limit: config.pageSize)
            lastPollError = nil
        } catch {
            lastPollError = String(describing: type(of: error))
            return []
        }
        let current = now()
        var results: [HearingPipeline.EnqueueResult] = []
        var newest = cursor
        for event in events.sorted(by: { $0.start < $1.start }) {
            guard event.start >= cursor.addingTimeInterval(-config.overlap) else { continue }
            guard let end = event.end, end.addingTimeInterval(config.settleDelay) <= current else { continue }
            results.append(await pipeline.enqueue(event))
            newest = max(newest, event.start)
        }
        if newest > cursor { saveCursor(newest) }
        return results
    }

    /// Called from the MQTT `end` path; waits for the clip to settle first.
    public func noteEnded(_ event: SpeechEvent) {
        guard event.isWellFormed, delayed[event.id] == nil else { return }
        let delay = config.settleDelay
        delayed[event.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            _ = await self.pipeline.enqueue(event)
            await self.finished(event.id)
        }
    }

    private func finished(_ id: String) { delayed[id] = nil }
}

/// The only thing a keyword alert may push: camera and an opaque event id.
/// No transcript text, no matched phrase — LorisLabs' relay must never see words.
public enum KeywordAlertEnvelope {
    public static let allowedKeys: Set<String> = [
        "source", "sourceSchema", "reviewId", "reviewSeverity", "eventId", "camera", "label",
        "detected_at", "score", "zones", "has_clip", "custom_title", "custom_body",
    ]

    /// `title` is the localized "Keyword heard"; `cameraDisplayName` the camera's name.
    public static func make(alert: KeywordAlert, reviewID: String, severity: String,
                            title: String, cameraDisplayName: String) -> [String: Any] {
        [
            "source": "lumen-hub",
            "sourceSchema": "frigate-review-v1",
            "reviewId": reviewID,
            "reviewSeverity": severity == "alert" ? "alert" : "detection",
            "eventId": alert.eventID,
            "camera": alert.camera,
            "label": "speech",
            "detected_at": alert.detectedAt.timeIntervalSince1970,
            "score": 1.0,
            "zones": [String](),
            "has_clip": true,
            "custom_title": title,
            "custom_body": cameraDisplayName,
        ]
    }
}
