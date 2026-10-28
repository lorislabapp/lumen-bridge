import XCTest
@testable import Lumen_Bridge

@MainActor
final class MailboxMonitorTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Event: Decodable {
            let id: String
            let camera: String
            let label: String
            let start_time: Double
            let end_time: Double
            let zones: [String]
            let sub_label: String?
            let false_positive: Bool
        }
        let events: [Event]
    }

    private static let config = MailboxMonitor.Configuration(camera: "front", mailboxZone: "mailbox")

    private func makeMonitor(_ config: MailboxMonitor.Configuration = config)
        -> (MailboxMonitor, () -> [MailboxMonitor.Visit]) {
        let monitor = MailboxMonitor()
        monitor.configure(config)
        var visits: [MailboxMonitor.Visit] = []
        monitor.onVisit = { visits.append($0) }
        return (monitor, { visits })
    }

    private func observation(_ id: String, _ kind: MailboxObservation.Kind, start: Double, end: Double? = nil,
                             zones: [String] = [], subLabel: String? = nil, camera: String = "front",
                             label: String = "person") -> MailboxObservation {
        MailboxObservation(id: id, camera: camera, label: label, kind: kind, zones: zones, subLabel: subLabel,
                           startTime: start, endTime: end, falsePositive: false)
    }

    /// Replays the owner's 20 real passes (12–19 Oct, anonymised): a `new`
    /// message at start and an `end` message with the final zones.
    private func realReplay() throws -> [MailboxObservation] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mailbox-front-real-20261012-19",
                                                          withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var timeline: [(Double, MailboxObservation)] = []
        for e in fixture.events {
            timeline.append((e.start_time, MailboxObservation(
                id: e.id, camera: e.camera, label: e.label, kind: .new, zones: [], subLabel: e.sub_label,
                startTime: e.start_time, endTime: nil, falsePositive: e.false_positive)))
            timeline.append((e.end_time, MailboxObservation(
                id: e.id, camera: e.camera, label: e.label, kind: .end, zones: e.zones, subLabel: e.sub_label,
                startTime: e.start_time, endTime: e.end_time, falsePositive: e.false_positive)))
        }
        return timeline.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func testRealWeekGivesSixVisits() throws {
        let (monitor, visits) = makeMonitor()
        try realReplay().forEach { monitor.consume($0) }
        XCTAssertEqual(visits().map { $0.eventIDs[0] }, [
            "1791787723.202537-z2xkbl", // 12/10 08:48 (+ 08:50 grouped)
            "1791789101.382818-oxnqsc", // 12/10 09:11
            "1791813008.544012-6zxitp", // 12/10 15:50 (+ 15:51 grouped)
            "1791991604.066752-42spal", // 14/10 17:26
            "1792070699.817032-31n23l", // 15/10 15:24
            "1792136348.559407-a7kg36", // 16/10 09:39 (+ 09:42, 09:45 grouped)
        ])
    }

    func testResidentPresentSuppressesTheUnnamedPass() throws {
        let (monitor, visits) = makeMonitor()
        try realReplay().forEach { monitor.consume($0) }
        XCTAssertFalse(visits().contains { $0.eventIDs.contains("1792423983.920096-2qpzz1") })
    }

    func testReplayedEndDoesNotNotifyTwice() {
        let (monitor, visits) = makeMonitor()
        let end = observation("a", .end, start: 1000, end: 1010, zones: ["parking", "mailbox"])
        monitor.consume(end)
        monitor.consume(end)
        XCTAssertEqual(visits().count, 1)
    }

    func testPassWithoutMailboxZoneIsIgnored() {
        let (monitor, visits) = makeMonitor()
        monitor.consume(observation("b", .end, start: 1000, end: 1010, zones: ["parking", "street"]))
        XCTAssertTrue(visits().isEmpty)
    }

    func testOtherCameraAndOtherLabelAreIgnored() {
        let (monitor, visits) = makeMonitor()
        monitor.consume(observation("c", .end, start: 1000, end: 1010, zones: ["mailbox"], camera: "back"))
        monitor.consume(observation("d", .end, start: 1000, end: 1010, zones: ["mailbox"], label: "car"))
        XCTAssertTrue(visits().isEmpty)
    }

    func testFaceRecognisedLaterInTheEventStillCountsAsResident() {
        let (monitor, visits) = makeMonitor()
        monitor.consume(observation("e", .new, start: 1000, zones: ["parking"]))
        monitor.consume(observation("e", .update, start: 1000, zones: ["parking", "mailbox"], subLabel: "Kevin"))
        monitor.consume(observation("e", .end, start: 1000, end: 1020, zones: ["parking", "mailbox"]))
        XCTAssertTrue(visits().isEmpty)
    }

    func testOnlyListedResidentNamesAreExcluded() {
        var config = Self.config
        config.residentNames = ["Kevin"]
        let (monitor, visits) = makeMonitor(config)
        monitor.consume(observation("f", .end, start: 1000, end: 1010, zones: ["mailbox"], subLabel: "facteur"))
        XCTAssertEqual(visits().count, 1)
    }

    func testReconnectForgetsEventsInFlight() {
        let (monitor, visits) = makeMonitor()
        monitor.consume(observation("g", .update, start: 1000, zones: ["mailbox"], subLabel: "Kevin"))
        monitor.connectionChanged(connected: true)
        monitor.consume(observation("h", .end, start: 1001, end: 1010, zones: ["mailbox"]))
        XCTAssertEqual(visits().count, 1, "resident track from before the reconnect is forgotten")
    }

    func testNoConfigurationMeansInactive() {
        let monitor = MailboxMonitor()
        var called = false
        monitor.onVisit = { _ in called = true }
        monitor.consume(observation("i", .end, start: 1000, end: 1010, zones: ["mailbox"]))
        XCTAssertFalse(monitor.isActive)
        XCTAssertFalse(called)
    }

    func testDecodesRealMQTTShape() throws {
        let json = """
        {"type":"update","before":{},"after":{"id":"1792136348.559407-a7kg36","camera":"front","label":"person",
         "sub_label":["Kevin",0.93],"start_time":1792136348.55,"end_time":null,"false_positive":false,
         "current_zones":["mailbox"],"entered_zones":["parking","mailbox"]}}
        """
        let o = try XCTUnwrap(MailboxObservation.decode(from: Data(json.utf8)))
        XCTAssertEqual(o.kind, .update)
        XCTAssertEqual(o.zones, ["parking", "mailbox"])
        XCTAssertEqual(o.subLabel, "Kevin")
        XCTAssertFalse(o.isFinished)
    }
}
