import SwiftUI
import AppKit

/// Menu-bar popover, direction C (docs/UI-SPEC-LumenHub-C.md): one sentence
/// on how things are, one row per active role, the last visit, and one way
/// into the window. Users glance, they don't read.
struct MenuBarContent: View {
    @Bindable var state: BridgeState
    var coordinator: BridgeCoordinator?
    var onSendTestEvent: (@MainActor () async -> Void)? = nil

    @Environment(\.openWindow) private var openWindow

    private var roles: [HubRole] { HubRole.all(from: state).filter { $0.tone != .later } }

    private var headline: String {
        let issues = roles.filter { $0.tone == .todo || $0.tone == .error }
        if issues.isEmpty { return String(localized: "All is well") }
        return issues.count == 1 ? String(localized: "One thing to set up")
                                 : String(localized: "\(issues.count) things to set up")
    }

    private var lastVisit: String? {
        guard let (id, date) = state.lastZoneVisits.max(by: { $0.value < $1.value }),
              let alert = state.zoneAlerts.first(where: { $0.id == id }) else { return nil }
        return String(localized: "Last visit: \(alert.name), \(date.formatted(date: .omitted, time: .shortened))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(HubPalette.ink)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(roles) { role in
                    HStack {
                        Text(role.title).font(.system(size: 13))
                        Spacer()
                        Text(role.status)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HubPalette.text(role.tone))
                    }
                }
            }

            if let lastVisit {
                Divider()
                Text(lastVisit)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button {
                openWindow(id: "lumenbridge-settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Open \(MainWindow.appName)")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(HubPalette.accent)
            .foregroundStyle(HubPalette.onAccent)
            .keyboardShortcut(",")

            HStack {
                Button(BridgeSupport.text("Help and ideas")) { BridgeSupportWindow.shared.show(state: state) }
                    .buttonStyle(.link)
                Spacer()
                Button(String(localized: "Quit")) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .keyboardShortcut("q")
            }
            .font(.system(size: 12))
        }
        .padding(18)
        .frame(width: 320)
    }
}
