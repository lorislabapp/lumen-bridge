import XCTest
@testable import Lumen_Bridge

final class ZoneAlertStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ZoneAlertStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMigratesLegacyMailboxSettingOnce() throws {
        let legacy = #"{"camera":"front","mailboxZone":"mailbox","groupWindowSeconds":300,"residentWindowSeconds":60,"residentNames":[]}"#
        defaults.set(Data(legacy.utf8), forKey: ZoneAlertStore.legacyMailboxKey)
        let alerts = ZoneAlertStore.load(defaults: defaults)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].configuration.camera, "front")
        XCTAssertEqual(alerts[0].configuration.labels, ["person"])
        XCTAssertTrue(alerts[0].configuration.ignoreRecognized)
        XCTAssertNil(defaults.data(forKey: ZoneAlertStore.legacyMailboxKey))
        XCTAssertEqual(ZoneAlertStore.load(defaults: defaults).map(\.id), alerts.map(\.id))
    }

    func testInvalidAlertsAreNotSaved() {
        let good = ZoneAlert(name: "Portail", configuration: .init(camera: "front", mailboxZone: "gate"))
        let noZone = ZoneAlert(name: "Allée", configuration: .init(camera: "front", mailboxZone: ""))
        ZoneAlertStore.save([good, noZone], defaults: defaults)
        XCTAssertEqual(ZoneAlertStore.load(defaults: defaults).map(\.name), ["Portail"])
    }

    @MainActor
    func testVehicleAlertIgnoresPeopleButResidentStillSilencesIt() {
        let monitor = MailboxMonitor()
        monitor.configure(.init(camera: "front", mailboxZone: "driveway", labels: ["car"]))
        var visits: [MailboxMonitor.Visit] = []
        monitor.onVisit = { visits.append($0) }
        func obs(_ id: String, _ label: String, _ kind: MailboxObservation.Kind, sub: String? = nil, end: Double? = nil)
            -> MailboxObservation {
            MailboxObservation(id: id, camera: "front", label: label, kind: kind, zones: ["driveway"],
                               subLabel: sub, startTime: 1000, endTime: end, falsePositive: false)
        }
        monitor.consume(obs("p", "person", .end, end: 1010))             // a person: not counted
        XCTAssertTrue(visits.isEmpty)
        monitor.consume(obs("c1", "car", .end, end: 1010))               // a car: visit
        XCTAssertEqual(visits.map(\.label), ["car"])
        monitor.consume(obs("k", "person", .update, sub: "Kevin"))       // resident arrives later
        monitor.consume(obs("c2", "car", .end, end: 2000))
        XCTAssertEqual(visits.count, 1, "resident nearby + within group window: no second alert")
    }
}
