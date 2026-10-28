import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "MailboxPush")

/// Sends a mailbox visit to the owner's iPhones through the existing
/// lumen-push Worker channel (the same one the relay uses).
///
/// The channel secret is the one the Lumen app shares through iCloud KVS
/// (`lumen_push_shared_secret`); it is never logged. The body is a regular
/// `frigate-review-v1` envelope tied to the visit's real Frigate review, with
/// `source: "lumen-hub"` so the Notification Service Extension shows the
/// Worker-rendered title untouched, and tapping opens the event's clip.
struct MailboxPushSender: Sendable {
    static let sharedSecretKVSKey = "lumen_push_shared_secret"
    static let workerBase = URL(string: "https://lumen-push.mail5491.workers.dev")!

    struct ReviewLink: Sendable, Equatable {
        let reviewID: String
        let severity: String
        let topScore: Double
    }

    enum Outcome: Sendable, Equatable {
        case sent
        case noSecret
        case noReview
        /// The channel has a signed automation policy; unsigned Hub pushes
        /// are refused (HTTP 428) until the Hub signs its decisions.
        case policyRequiresSignature
        case rejected(Int)
        case failed
    }

    var session: URLSession = .shared
    var secretProvider: @Sendable () -> String? = {
        NSUbiquitousKeyValueStore.default.string(forKey: MailboxPushSender.sharedSecretKVSKey)
    }

    static func channelID(forSecret secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pure envelope builder (unit-tested).
    static func envelope(visit: MailboxMonitor.Visit, review: ReviewLink, alertName: String, zone: String,
                         now: Date = Date()) -> [String: Any] {
        let camera = visit.camera.replacingOccurrences(of: "_", with: " ").capitalized
        let who: String
        switch visit.label {
        case "person": who = String(localized: "unrecognised person", comment: "Zone alert: who passed")
        case "car": who = String(localized: "vehicle", comment: "Zone alert: who passed")
        default: who = visit.label.replacingOccurrences(of: "_", with: " ")
        }
        return [
            "source": "lumen-hub",
            "sourceSchema": "frigate-review-v1",
            "reviewId": review.reviewID,
            "reviewSeverity": review.severity == "alert" ? "alert" : "detection",
            "eventId": visit.eventIDs[0],
            "camera": visit.camera,
            "label": visit.label,
            "detected_at": now.timeIntervalSince1970,
            "score": min(1, max(0, review.topScore)),
            "zones": [zone],
            "has_clip": true,
            "custom_title": alertName,
            "custom_body": String(localized: "\(camera) · \(who)",
                                  comment: "iPhone notification body: camera name · who"),
        ]
    }

    func send(visit: MailboxMonitor.Visit, review: ReviewLink?, alertName: String, zone: String) async -> Outcome {
        guard let secret = secretProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              secret.count == 32, secret.allSatisfy(\.isHexDigit) else { return .noSecret }
        guard let review else { return .noReview }
        let url = Self.workerBase.appendingPathComponent("v2/notify/\(Self.channelID(forSecret: secret))")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(
            withJSONObject: Self.envelope(visit: visit, review: review, alertName: alertName, zone: zone)) else { return .failed }
        request.httpBody = body
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .sent
            case 428: return .policyRequiresSignature
            default: return .rejected(status)
            }
        } catch {
            logger.error("mailbox push failed: \(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }
}
