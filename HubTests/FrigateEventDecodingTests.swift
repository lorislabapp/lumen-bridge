import FrigateKit
import XCTest
@testable import Lumen_Bridge

/// Payloads follow Frigate's documented `frigate/events` MQTT shape
/// (before/after, current_zones, entered_zones, frame_time). They are
/// doc-shaped, not captured: replace with real captures from the owner's
/// server before relying on timing behaviour.
final class FrigateEventDecodingTests: XCTestCase {
    private static func state(
        id: String = "1760900000.123456-abc123",
        camera: String = "front",
        label: String = "person",
        frameTime: Double,
        current: [String],
        entered: [String],
        subLabel: String = "null",
        endTime: String = "null"
    ) -> String {
        let cur = current.map { "\"\($0)\"" }.joined(separator: ",")
        let ent = entered.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","camera":"\(camera)","frame_time":\(frameTime),"label":"\(label)",
         "sub_label":\(subLabel),"top_score":0.91,"false_positive":false,"start_time":1760900000.1,
         "end_time":\(endTime),"score":0.9,"box":[10,10,50,90],"area":3200,"ratio":0.5,
         "region":[0,0,320,320],"current_zones":[\(cur)],"entered_zones":[\(ent)],
         "has_clip":true,"has_snapshot":true,"stationary":false,"motionless_count":0,
         "position_changes":1,"attributes":{},"current_attributes":[]}
        """
    }

    private static func message(type: String, before: String, after: String) -> Data {
        Data("{\"type\":\"\(type)\",\"before\":\(before),\"after\":\(after)}".utf8)
    }

    func testEventZonesComeFromEnteredAndCurrentZones() throws {
        let s = Self.state(frameTime: 1760900001, current: ["mailbox"], entered: ["street", "mailbox"])
        let event = try XCTUnwrap(FrigateMQTTClient.decodeEvent(from: Self.message(type: "new", before: s, after: s)))
        XCTAssertEqual(event.zones, ["street", "mailbox"])
    }

    func testSubLabelAsNameScorePair() throws {
        let s = Self.state(frameTime: 1760900001, current: [], entered: [], subLabel: "[\"Kevin\",0.92]")
        let event = try XCTUnwrap(FrigateMQTTClient.decodeEvent(from: Self.message(type: "new", before: s, after: s)))
        XCTAssertEqual(event.subLabel, "Kevin")
    }

    func testSubLabelAsPlainString() throws {
        let s = Self.state(frameTime: 1760900001, current: [], entered: [], subLabel: "\"Kevin\"")
        let event = try XCTUnwrap(FrigateMQTTClient.decodeEvent(from: Self.message(type: "new", before: s, after: s)))
        XCTAssertEqual(event.subLabel, "Kevin")
    }

    func testUpdateDecodesAsTransitionButNotAsNotificationEvent() throws {
        let before = Self.state(frameTime: 1760900001, current: ["street"], entered: ["street"])
        let after = Self.state(frameTime: 1760900002, current: ["mailbox"], entered: ["street", "mailbox"])
        let data = Self.message(type: "update", before: before, after: after)
        XCTAssertNil(FrigateMQTTClient.decodeEvent(from: data))
        let transition = try XCTUnwrap(FrigateMQTTClient.decodeTransition(from: data))
        XCTAssertEqual(transition.before.currentZones, ["street"])
        XCTAssertEqual(transition.after.currentZones, ["mailbox"])
        XCTAssertEqual(transition.after.frameTime, 1760900002)
    }

    func testStatsPayloadListsCameras() {
        let json = #"{"cameras":{"front":{"camera_fps":5},"back_yard":{"camera_fps":5}},"service":{"version":"0.17.0"}}"#
        XCTAssertEqual(FrigateMQTTClient.decodeStatsCameras(from: Data(json.utf8)), ["back_yard", "front"])
        XCTAssertEqual(FrigateMQTTClient.decodeStatsCameras(from: Data("<html>".utf8)), [])
    }

    func testRetainedDetectStateTopicGivesCameraName() {
        XCTAssertEqual(FrigateMQTTClient.cameraFromStateTopic("frigate/front/detect/state"), "front")
        XCTAssertNil(FrigateMQTTClient.cameraFromStateTopic("frigate/front/person/snapshot"))
        XCTAssertNil(FrigateMQTTClient.cameraFromStateTopic("frigate/events"))
    }

    func testBackwardsFrameTimeIsRejected() {
        let before = Self.state(frameTime: 1760900005, current: [], entered: [])
        let after = Self.state(frameTime: 1760900004, current: [], entered: [])
        XCTAssertNil(FrigateMQTTClient.decodeTransition(from: Self.message(type: "update", before: before, after: after)))
    }

    /// street → mailbox (dwell) → street-side departure zone, all through
    /// the real MQTT decoder and the shared FrigateKit engine.
    func testDecodedSequenceCompletesMailboxVisit() throws {
        var engine = try MailboxVisitSequence(
            configuration: .init(camera: "front", mailboxZone: "mailbox", departureZone: "street",
                                 dwellSeconds: 2, timeoutSeconds: 120),
            sourceID: "test-server", epoch: "e1")
        let steps: [(Double, [String], [String])] = [
            (1760900001, ["passage"], ["passage"]),
            (1760900002, ["mailbox"], ["passage", "mailbox"]),
            (1760900005, ["mailbox"], ["passage", "mailbox"]),
            (1760900007, ["passage"], ["passage", "mailbox"]),
            (1760900009, ["street"], ["passage", "mailbox", "street"]),
        ]
        var previous = Self.state(frameTime: 1760900000, current: [], entered: [])
        var last: MailboxVisitSequence.Evidence?
        for (index, step) in steps.enumerated() {
            let after = Self.state(frameTime: step.0, current: step.1, entered: step.2)
            let data = Self.message(type: index == 0 ? "new" : "update", before: previous, after: after)
            let transition = try XCTUnwrap(FrigateMQTTClient.decodeTransition(from: data))
            last = engine.consume(transition)
            previous = after
        }
        XCTAssertEqual(last?.state, .completed)
        XCTAssertEqual(last?.newCompletion, true)
    }
}
