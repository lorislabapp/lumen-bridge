import XCTest
@testable import BugReportKit

/// Unit tests for `BugTriageService.fallback(description:)` — the
/// keyword-based classifier used when Apple Intelligence is unavailable.
///
/// These don't exercise the AI path itself (Foundation Models output isn't
/// deterministic enough for unit tests), only the deterministic fallback
/// that ships on every device.
final class BugTriageFallbackTests: XCTestCase {

    // MARK: - Category classification

    func testClassifiesStreamingBug() {
        let triage = BugTriageService.fallback(description: "the live streams won't load on my iPhone")
        XCTAssertEqual(triage.category, .streaming)
        XCTAssertTrue(triage.infoNeeded.contains(.frigateVersion))
        XCTAssertTrue(triage.infoNeeded.contains(.authMode))
    }

    func testClassifiesAuthBug() {
        let triage = BugTriageService.fallback(description: "I can't login through Cloudflare Access")
        XCTAssertEqual(triage.category, .auth)
    }

    func testClassifiesNotificationsBug() {
        let triage = BugTriageService.fallback(description: "push notifications arrive 30 minutes late")
        XCTAssertEqual(triage.category, .notifications)
    }

    func testClassifiesRecordingsBug() {
        let triage = BugTriageService.fallback(description: "every clip says recording unavailable")
        XCTAssertEqual(triage.category, .recordings)
    }

    func testClassifiesEventsBug() {
        let triage = BugTriageService.fallback(description: "the events tab is empty since today")
        XCTAssertEqual(triage.category, .events)
    }

    func testClassifiesUIBug() {
        let triage = BugTriageService.fallback(description: "the back button is broken after watching a clip")
        XCTAssertEqual(triage.category, .ui)
    }

    func testClassifiesWatchBug() {
        let triage = BugTriageService.fallback(description: "the watch app says no server")
        XCTAssertEqual(triage.category, .watch)
    }

    func testClassifiesWidgetBug() {
        let triage = BugTriageService.fallback(description: "the home screen widget shows old data")
        XCTAssertEqual(triage.category, .widgets)
    }

    func testClassifiesUnknownAsOther() {
        let triage = BugTriageService.fallback(description: "asdf zxcv qwerty")
        XCTAssertEqual(triage.category, .other)
    }

    // MARK: - Severity classification

    func testCriticalKeywords() {
        XCTAssertEqual(BugTriageService.fallback(description: "the app crashes when I add a server").severity, .critical)
        XCTAssertEqual(BugTriageService.fallback(description: "Lumen freezes on launch").severity, .critical)
    }

    func testQuestionPhrasing() {
        XCTAssertEqual(BugTriageService.fallback(description: "How do I switch to the high-quality stream?").severity, .question)
    }

    func testMajorBrokenFeature() {
        XCTAssertEqual(BugTriageService.fallback(description: "notifications are not working").severity, .major)
    }

    // MARK: - Word-boundary correctness

    func testNavInsideUnavailableDoesNotMisclassifyAsUI() {
        // "una-nav-ailable" must not be matched on the "nav" UI keyword.
        let triage = BugTriageService.fallback(description: "every clip says recording unavailable")
        XCTAssertEqual(triage.category, .recordings, "must not match 'nav' substring inside 'unavailable'")
    }

    func testWatchInsideWatchingDoesNotMisclassifyAsWatchApp() {
        let triage = BugTriageService.fallback(description: "the back button is broken after watching a clip")
        XCTAssertEqual(triage.category, .ui, "must not match 'watch' substring inside 'watching'")
    }

    // MARK: - DiagnosticField fillability

    func testAutoFillableFlagsAreCorrect() {
        XCTAssertTrue(DiagnosticField.appBuild.isAutoFillable)
        XCTAssertTrue(DiagnosticField.osVersion.isAutoFillable)
        XCTAssertTrue(DiagnosticField.frigateVersion.isAutoFillable)
        XCTAssertFalse(DiagnosticField.reproSteps.isAutoFillable)
        XCTAssertFalse(DiagnosticField.lastWorkingDate.isAutoFillable)
        XCTAssertFalse(DiagnosticField.proxySetup.isAutoFillable)
    }

    // MARK: - Triage terminator parser

    @available(iOS 26, macOS 26, visionOS 26, *)
    @MainActor
    func testParsesTerminalTriage() {
        let raw = """
        Got it, I'll wrap up.

        TRIAGE: {"category":"streaming","severity":"major","infoNeeded":["frigateVersion","authMode"],"suggestedFollowUp":null}
        """
        let parsed = BugReportConversationService.tryParseTerminalTriage(raw)
        XCTAssertEqual(parsed?.category, .streaming)
        XCTAssertEqual(parsed?.severity, .major)
    }

    @available(iOS 26, macOS 26, visionOS 26, *)
    @MainActor
    func testIgnoresPlainAssistantTextWithoutMarker() {
        let raw = "I think I need a bit more info — when did this last work?"
        XCTAssertNil(BugReportConversationService.tryParseTerminalTriage(raw))
    }
}
