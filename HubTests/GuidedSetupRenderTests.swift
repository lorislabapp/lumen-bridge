import AppKit
import SwiftUI
import XCTest
@testable import Lumen_Bridge

/// Offline rendering evidence: no coordinator, network calls, credentials or saved configuration.
final class GuidedSetupRenderTests: XCTestCase {
    @MainActor
    func testGuidedScreensAtMinimumWindowSize() throws {
        for step in OnboardingView.Step.allCases {
            try capture(step, size: NSSize(width: 760, height: 640), name: "minimum")
        }
    }

    @MainActor
    func testGuidedScreensAtDefaultWindowSize() throws {
        for step in OnboardingView.Step.allCases {
            try capture(step, size: NSSize(width: 820, height: 700), name: "default")
        }
    }

    @MainActor
    func testGuidedScreensInDarkAppearance() throws {
        for step in OnboardingView.Step.allCases {
            try capture(step, appearance: .darkAqua, name: "dark")
        }
    }

    @MainActor
    func testGuidedRecoveryAndPairingScreens() throws {
        try capture(.notifications, name: "no-account") { $0.cloudKitStatus = .noAccount }
        try capture(.home, name: "home-error") { $0.hapStatus = .error("Synthetic HomeKit startup failure") }
        try capture(.home, name: "pairing") {
            $0.hapStatus = .running(setupCode: "111-22-333", setupID: "TEST", accessoryCount: 1)
        }
        try capture(.ai, name: "disconnected") { $0.mqttConnected = false }
    }

    @MainActor
    private func capture(_ step: OnboardingView.Step,
                         size: NSSize = NSSize(width: 760, height: 640),
                         appearance: NSAppearance.Name = .aqua,
                         name: String,
                         configure: (BridgeState) -> Void = { _ in }) throws {
        let state = BridgeState()
        state.mqttConnected = true
        state.cloudKitStatus = .available
        state.frigateHost = "frigate.example.invalid"
        state.frigatePort = 1883
        state.learn(camera: "front", zones: ["mailbox"], label: "person")
        configure(state)
        let view = NSHostingView(rootView: OnboardingView(state: state, coordinator: nil, initialStep: step)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        view.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(view.bounds.height, size.height, accuracy: 1)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "guided-\(step.rawValue)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
