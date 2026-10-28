import XCTest
@testable import Lumen_Bridge

final class MailboxPushSenderTests: XCTestCase {
    private let visit = MailboxMonitor.Visit(
        eventIDs: ["1792136348.559407-a7kg36"], camera: "front",
        start: Date(timeIntervalSince1970: 1792136348), end: Date(timeIntervalSince1970: 1792136380))

    /// Same derivation as the app's PushConfig: channel = SHA-256(secret) hex.
    func testChannelIDIsSHA256HexOfSecret() {
        XCTAssertEqual(MailboxPushSender.channelID(forSecret: "abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Must satisfy the Worker's frigate-review-v1 validation and stay out of
    /// the NSE relay filter (source is not cloudflare-relay / mqtt-relay).
    func testEnvelopeMatchesWorkerContract() {
        let now = Date(timeIntervalSince1970: 1792136390)
        let body = MailboxPushSender.envelope(
            visit: visit, review: .init(reviewID: "1792136348.5-r1", severity: "alert", topScore: 0.87),
            alertName: "Boîte aux lettres", zone: "mailbox", now: now)
        XCTAssertEqual(body["source"] as? String, "lumen-hub")
        XCTAssertEqual(body["sourceSchema"] as? String, "frigate-review-v1")
        XCTAssertEqual(body["reviewId"] as? String, "1792136348.5-r1")
        XCTAssertEqual(body["reviewSeverity"] as? String, "alert")
        XCTAssertEqual(body["eventId"] as? String, "1792136348.559407-a7kg36")
        XCTAssertEqual(body["camera"] as? String, "front")
        XCTAssertEqual(body["label"] as? String, "person")
        XCTAssertEqual(body["detected_at"] as? Double, 1792136390)
        XCTAssertEqual(body["score"] as? Double, 0.87)
        XCTAssertEqual(body["zones"] as? [String], ["mailbox"])
        XCTAssertEqual(body["custom_title"] as? String, "Boîte aux lettres")
        XCTAssertNotNil(body["custom_body"] as? String)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: body))
    }

    func testUnknownSeverityFallsBackToDetectionAndScoreIsClamped() {
        let body = MailboxPushSender.envelope(
            visit: visit, review: .init(reviewID: "r", severity: "significant_motion", topScore: 1.4),
            alertName: "Boîte aux lettres", zone: "mailbox")
        XCTAssertEqual(body["reviewSeverity"] as? String, "detection")
        XCTAssertEqual(body["score"] as? Double, 1)
    }

    func testMissingOrMalformedSecretNeverSends() async {
        var sender = MailboxPushSender()
        sender.secretProvider = { nil }
        let none = await sender.send(visit: visit, review: .init(reviewID: "r", severity: "alert", topScore: 0.9),
                                     alertName: "Boîte aux lettres", zone: "mailbox")
        XCTAssertEqual(none, .noSecret)
        sender.secretProvider = { "not-a-secret" }
        let bad = await sender.send(visit: visit, review: .init(reviewID: "r", severity: "alert", topScore: 0.9),
                                    alertName: "Boîte aux lettres", zone: "mailbox")
        XCTAssertEqual(bad, .noSecret)
    }

    func testNoReviewNeverSends() async {
        var sender = MailboxPushSender()
        sender.secretProvider = { String(repeating: "a", count: 32) }
        let outcome = await sender.send(visit: visit, review: nil, alertName: "Boîte aux lettres", zone: "mailbox")
        XCTAssertEqual(outcome, .noReview)
    }
}
