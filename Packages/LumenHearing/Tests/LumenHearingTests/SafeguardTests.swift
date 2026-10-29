import Foundation
import Testing
@testable import LumenHearing

@Suite struct SafeguardTests {
    let consentDate = Date(timeIntervalSince1970: 1_800_000_000)

    func consented(_ camera: String = "salon") throws -> HearingSettings {
        var s = HearingSettings()
        s.enabled = true
        try s.grantConsent(camera: camera, placement: .indoor, at: consentDate)
        return s
    }

    @Test func everythingIsOffByDefault() {
        let s = HearingSettings()
        #expect(s.enabled == false)
        #expect(s.cameras.isEmpty)
        #expect(s.keywords.isEmpty)
        #expect(s.staffPresent == false)
        #expect(s.retentionDays == 30)
        #expect(s.eligibility(camera: "salon") == .blocked(.featureOff))
        #expect(HearingSettingsStore(suiteName: "lumenhearing.tests.\(UUID())").load() == HearingSettings())
    }

    @Test func emptyOrPartialJSONDecodesToPrivateDefaults() throws {
        let s = try JSONDecoder().decode(HearingSettings.self, from: Data("{}".utf8))
        #expect(s == HearingSettings())
        let odd = try JSONDecoder().decode(HearingSettings.self,
            from: Data(#"{"enabled":true,"retentionDays":365,"engine":"whisper"}"#.utf8))
        #expect(odd.retentionDays == 30)
        #expect(odd.engine == .automatic)
    }

    @Test func featureOnButNoCameraOptedIn() {
        var s = HearingSettings()
        s.enabled = true
        #expect(s.eligibility(camera: "salon") == .blocked(.cameraNotEnabled))
        #expect(throws: HearingSettings.ChangeError.consentRequired) { try s.setCamera("salon", enabled: true) }
    }

    @Test func consentedIndoorCameraIsAllowed() throws {
        let s = try consented()
        #expect(s.eligibility(camera: "salon", eventStart: consentDate.addingTimeInterval(5)) == .allowed)
        #expect(s.activeCameras == ["salon"])
    }

    @Test func eventsBeforeConsentAreRefused() throws {
        let s = try consented()
        #expect(s.eligibility(camera: "salon", eventStart: consentDate.addingTimeInterval(-1)) == .blocked(.beforeConsent))
    }

    @Test func outdoorAndStreetCamerasAreLockedOff() throws {
        var s = HearingSettings()
        s.enabled = true
        #expect(throws: HearingSettings.ChangeError.outdoorLocked) { try s.grantConsent(camera: "jardin", placement: .outdoor) }
        #expect(throws: HearingSettings.ChangeError.outdoorLocked) { try s.grantConsent(camera: "rue", placement: .street) }
        #expect(s.eligibility(camera: "jardin") == .blocked(.outdoorLocked))
        #expect(s.eligibility(camera: "rue") == .blocked(.outdoorLocked))
        #expect(throws: HearingSettings.ChangeError.outdoorLocked) { try s.setCamera("jardin", enabled: true) }
        // Even a hand-edited policy that claims enabled stays locked.
        s.cameras["rue"]?.enabled = true
        #expect(s.eligibility(camera: "rue") == .blocked(.outdoorLocked))
    }

    @Test func markingACameraOutdoorTurnsItOffAndClearsConsent() throws {
        var s = try consented()
        s.setPlacement(.street, camera: "salon")
        #expect(s.eligibility(camera: "salon") == .blocked(.outdoorLocked))
        s.setPlacement(.indoor, camera: "salon")
        #expect(s.eligibility(camera: "salon") == .blocked(.cameraNotEnabled))
        #expect(throws: HearingSettings.ChangeError.consentRequired) { try s.setCamera("salon", enabled: true) }
    }

    @Test func staffModeBlocksEveryCamera() throws {
        var s = try consented()
        s.staffPresent = true
        #expect(s.eligibility(camera: "salon", eventStart: consentDate.addingTimeInterval(5)) == .blocked(.staffPresent))
        #expect(s.activeCameras.isEmpty)
    }

    @Test func outdatedConsentVersionNeedsNewConsent() throws {
        var s = try consented()
        s.cameras["salon"]?.consentVersion = HearingSettings.consentVersion - 1
        #expect(s.eligibility(camera: "salon") == .blocked(.consentMissing))
    }

    @Test func placementSuggestionsFromCameraNames() {
        #expect(HearingSettings.suggestedPlacement(cameraName: "rue_principale") == .street)
        #expect(HearingSettings.suggestedPlacement(cameraName: "Front_Door") == .outdoor)
        #expect(HearingSettings.suggestedPlacement(cameraName: "jardin") == .outdoor)
        #expect(HearingSettings.suggestedPlacement(cameraName: "allée") == .outdoor)
        #expect(HearingSettings.suggestedPlacement(cameraName: "salon") == .indoor)
        #expect(HearingSettings.suggestedPlacement(cameraName: "cam3") == nil)
    }

    @Test func retentionIsClampedToAllowedChoices() {
        var s = HearingSettings()
        s.setRetention(days: 365)
        #expect(s.retentionDays == 30)
        s.setRetention(days: 10)
        #expect(s.retentionDays == 7)
        s.setRetention(days: 0)
        #expect(s.retentionDays == 1)
    }

    @Test func keywordsAreSanitized() {
        var s = HearingSettings()
        s.setKeywords(["  Au secours ", "au SÉCOURS", "a", String(repeating: "x", count: 41), "help"]
                      + (0..<30).map { "mot\($0)" })
        #expect(s.keywords.first == "Au secours")
        #expect(s.keywords.contains("help"))
        #expect(!s.keywords.contains("a"))
        #expect(s.keywords.count == HearingSettings.maxKeywords)
    }
}
