import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Lumen_Bridge

/// Mac App Store screenshots rendered from the real SwiftUI views with
/// fixture state only: placeholder host, generic camera names, fake HomeKit
/// setup code. No coordinator, no MQTT, no CloudKit, no HomeKit server.
///
/// Opt-in (skipped in normal test runs). Run, per language:
///   TEST_RUNNER_LUMEN_STORE_SCREENSHOTS=1 xcodebuild test -scheme LumenBridge \
///     -only-testing:LumenBridgeTests/AppStoreScreenshotTests \
///     -testLanguage fr -testRegion FR -resultBundlePath <out>.xcresult
/// then `xcrun xcresulttool export attachments --path <out>.xcresult --output-path <dir>`.
/// Output: PNG attachments, 2880×1800 px (1440×900 pt at 2×), dark appearance.
/// The attachments miss the sidebar (vibrancy is not drawn by cacheDisplay),
/// so the published set comes from hold mode: TEST_RUNNER_LUMEN_STORE_SCREENSHOTS_HOLD=6
/// keeps each real window on screen while `screencapture -o -l <windowID>`
/// grabs it, then the PNG is flattened onto an opaque background.
/// Frigate / onboarding-notification screens are not captured: build 19 shows
/// the MQTT port with a thousands separator ("8,883") and a disabled test button.
final class AppStoreScreenshotTests: XCTestCase {
    private static let pointSize = NSSize(width: 1440, height: 900)
    private static let pixelSize = (width: 2880, height: 1800)

    /// UserDefaults keys the rendered views read. Saved and restored so the
    /// harness never changes the host app's real settings.
    private static let touchedKeys = [
        "lumenbridge.mainwindow.section",
        "lumenbridge.window.showsSettings",
        "lumenbridge.mqtt.use_tls", // BridgeCoordinator.mqttUseTLSKey (main-actor isolated)
        "lumenbridge.hap.enabled",
    ]
    private var savedDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_STORE_SCREENSHOTS"] == "1",
                          "Store screenshots are opt-in (TEST_RUNNER_LUMEN_STORE_SCREENSHOTS=1).")
        for key in Self.touchedKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
        UserDefaults.standard.set(true, forKey: "lumenbridge.mqtt.use_tls")
        UserDefaults.standard.set(true, forKey: "lumenbridge.hap.enabled")
    }

    override func tearDown() {
        for key in Self.touchedKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Screens

    @MainActor
    func test01Home() throws {
        let state = Self.fixtureState()
        try capture(name: "01-home",
                    HubHomeView(state: state, onSetup: {}, open: { _ in }))
    }

    @MainActor
    func test02ZoneAlerts() throws {
        try captureMainWindow(.zoneAlerts, name: "02-zone-alerts")
    }

    @MainActor
    func test03HomeKit() throws {
        try captureMainWindow(.sensors, name: "03-homekit")
    }

    // MARK: - Fixture

    @MainActor
    private static func fixtureState() -> BridgeState {
        let state = BridgeState()
        state.mqttConnected = true
        state.mqttEncrypted = true
        state.cloudKitStatus = .available
        state.frigateHost = "frigate.local"
        state.frigatePort = 8883
        state.mqttUsername = "lumen"
        state.mqttPassword = "fixture-only"
        state.eventsReceived = 128
        state.eventsForwarded = 41
        state.lastEventAt = Date()
        state.notificationTestSentAt = Date()
        state.learn(camera: "street", zones: ["mailbox", "sidewalk"], label: "person")
        state.learn(camera: "entrance", zones: ["doorstep"], label: "person")
        state.learn(camera: "driveway", zones: ["gate"], label: "car")
        state.learn(camera: "garden", zones: ["lawn"], label: "dog")
        state.hapStatus = .running(setupCode: "482-91-306", setupID: "LMBR", accessoryCount: 6)
        state.discoveredInstances = [
            DiscoveredFrigate(id: "Frigate", host: "frigate.local", port: 8883, netServiceName: "Frigate"),
        ]

        let mailbox = ZoneAlert(name: String(localized: "Mailbox"),
                                configuration: .init(camera: "street", mailboxZone: "mailbox"))
        let door = ZoneAlert(name: String(localized: "Front door"),
                             configuration: .init(camera: "entrance", mailboxZone: "doorstep"))
        state.zoneAlerts = [mailbox, door]
        let today = Calendar.current.startOfDay(for: Date())
        state.lastZoneVisits[mailbox.id] = today.addingTimeInterval(10 * 3600 + 42 * 60)
        state.lastZonePushOutcome[mailbox.id] = "sent"
        state.lastZoneVisits[door.id] = today.addingTimeInterval(8 * 3600 + 15 * 60)
        state.lastZonePushOutcome[door.id] = "sent"
        return state
    }

    // MARK: - Rendering

    @MainActor
    private func captureMainWindow(_ section: MainWindow.Section, name: String) throws {
        UserDefaults.standard.set(section.rawValue, forKey: "lumenbridge.mainwindow.section")
        let state = Self.fixtureState()
        try capture(name: name, MainWindow(state: state, coordinator: nil,
                                           onApplyConnection: { _, _, _, _ in },
                                           onToggleHAP: { _ in },
                                           onToggleHomebridge: { _ in },
                                           onSendTestEvent: {}))
    }

    @MainActor
    private func capture<V: View>(name: String, _ root: V) throws {
        let size = Self.pointSize
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = MainWindow.appName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Same as the real window (HubRootView): a regular app while shown,
        // so the window can be key and controls draw in their active colours.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        // Hold mode: keep the real window on screen so an external
        // `screencapture -o -l <windowID>` can grab the composited window
        // (sidebar vibrancy is not reproduced by cacheDisplay).
        if let hold = ProcessInfo.processInfo.environment["LUMEN_STORE_SCREENSHOTS_HOLD"].flatMap(Double.init) {
            RunLoop.current.run(until: Date().addingTimeInterval(hold))
        }

        // Whole window (title bar + toolbar + content) when available.
        let target: NSView = hosting.superview ?? hosting
        let bounds = target.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: Self.pixelSize.width,
                                                 pixelsHigh: Self.pixelSize.height,
                                                 bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        target.cacheDisplay(in: bounds, to: rep)

        // App Store rejects alpha: flatten onto an opaque RGB canvas.
        let source = try XCTUnwrap(rep.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil,
                                              width: Self.pixelSize.width, height: Self.pixelSize.height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let canvas = CGRect(x: 0, y: 0, width: Self.pixelSize.width, height: Self.pixelSize.height)
        context.setFillColor(CGColor(gray: 0.11, alpha: 1))
        context.fill(canvas)
        context.draw(source, in: canvas)
        let flattened = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(flattened.width, Self.pixelSize.width)
        XCTAssertEqual(flattened.height, Self.pixelSize.height)
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, flattened, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let attachment = XCTAttachment(data: png as Data, uniformTypeIdentifier: "public.png")
        attachment.name = "store-\(lang)-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
