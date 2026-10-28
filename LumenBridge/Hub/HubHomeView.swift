import AppKit
import SwiftUI

// Direction C « Accueil » — docs/UI-SPEC-LumenHub-C.md.

/// Palette from the spec, with dark-mode counterparts.
enum HubPalette {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
    static let ground = dynamic(hex(0xF4F1EA), hex(0x1A1814))
    static let panel = dynamic(hex(0xFFFFFF), hex(0x24211C))
    static let border = dynamic(hex(0xE3E3E8), hex(0x3A362F))
    static let ink = dynamic(hex(0x1D1D1F), hex(0xF5F2EC))
    static let accent = Color(nsColor: hex(0xF5B544))
    static let onAccent = Color(nsColor: hex(0x1D1D1F))

    static func text(_ tone: HubRole.Tone) -> Color {
        switch tone {
        case .ok: return dynamic(hex(0x1E7B34), hex(0x5DD47A))
        case .todo: return dynamic(hex(0x8A5A00), hex(0xF5B544))
        case .error: return dynamic(hex(0xC4312A), hex(0xFF7A70))
        case .later: return .secondary
        }
    }
    static func tile(_ tone: HubRole.Tone) -> Color {
        switch tone {
        case .ok: return dynamic(hex(0xE8F7EC), hex(0x1F3A26))
        case .todo: return dynamic(hex(0xFFF4DE), hex(0x3D2F14))
        case .error: return dynamic(hex(0xFDECEA), hex(0x45201D))
        case .later: return dynamic(hex(0xF2F2F5), hex(0x2E2B26))
        }
    }
}

/// Keeps action contrast consistent when macOS de-emphasises an inactive window.
struct HubActionStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .foregroundStyle(prominent && isEnabled ? HubPalette.onAccent : HubPalette.ink)
            .background(prominent && isEnabled ? HubPalette.accent : HubPalette.tile(.later),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

/// One thing the Mac does for the owner, with its plain-language status.
struct HubRole: Identifiable {
    enum Tone { case ok, todo, error, later }
    struct Action { let title: String; let section: MainWindow.Section }

    let id: String
    let title: String
    let systemImage: String
    let tone: Tone
    let status: String
    let detail: String
    var action: Action?

    @MainActor
    static func all(from state: BridgeState) -> [HubRole] {
        [frigate(state), notifications(state), home(state), alerts(state)]
    }

    @MainActor private static func frigate(_ s: BridgeState) -> HubRole {
        let cameras = s.seenZones.count
        if s.mqttConnected {
            let detail = cameras > 0
                ? String(localized: "\(cameras) cameras seen · \(s.eventsReceived) events since launch")
                : String(localized: "Waiting for the first detection")
            return HubRole(id: "frigate", title: "Frigate", systemImage: "video", tone: .ok,
                           status: String(localized: "Connected"), detail: detail)
        }
        if s.frigateHost == nil {
            return HubRole(id: "frigate", title: "Frigate", systemImage: "video", tone: .todo,
                           status: String(localized: "To connect"),
                           detail: String(localized: "Tell the Hub where your Frigate server is."),
                           action: .init(title: String(localized: "Connect Frigate"), section: .connection))
        }
        return HubRole(id: "frigate", title: "Frigate", systemImage: "video", tone: .error,
                       status: String(localized: "Disconnected"),
                       detail: s.lastMQTTError.map { _ in String(localized: "The Hub cannot reach your MQTT server.") }
                           ?? String(localized: "Connecting…"),
                       action: .init(title: String(localized: "Check the connection"), section: .connection))
    }

    @MainActor private static func notifications(_ s: BridgeState) -> HubRole {
        switch s.cloudKitStatus {
        case .available:
            return HubRole(id: "push", title: String(localized: "Notifications"), systemImage: "iphone", tone: .todo,
                           status: String(localized: "iCloud ready"),
                           detail: s.notificationTestSentAt == nil
                             ? String(localized: "Send a test and confirm it arrives on your iPhone.")
                             : String(localized: "Test sent to iCloud · receipt on your iPhone still needs confirmation"),
                           action: .init(title: String(localized: "Test notifications"), section: .iCloud))
        case .unknown:
            return HubRole(id: "push", title: String(localized: "Notifications"), systemImage: "iphone", tone: .later,
                           status: String(localized: "Checking…"),
                           detail: String(localized: "Checking your iCloud account."))
        case .noAccount:
            return HubRole(id: "push", title: String(localized: "Notifications"), systemImage: "iphone", tone: .todo,
                           status: String(localized: "iCloud needed"),
                           detail: String(localized: "Sign in to iCloud on this Mac to notify your devices."),
                           action: .init(title: String(localized: "Open iCloud settings"), section: .iCloud))
        case .error:
            return HubRole(id: "push", title: String(localized: "Notifications"), systemImage: "iphone", tone: .error,
                           status: String(localized: "Error"),
                           detail: String(localized: "iCloud refused the connection."),
                           action: .init(title: String(localized: "See details"), section: .iCloud))
        }
    }

    @MainActor private static func home(_ s: BridgeState) -> HubRole {
        #if os(macOS) && LUMEN_HUB
        if !s.cameraStatuses.isEmpty || s.homebridgeStatus.isRunning {
            let failures = s.cameraStatuses.filter { $0.phase == .unavailable }.count
            let playing = s.cameraStatuses.filter { $0.phase == .playing }.count
            let ready = s.cameraStatuses.filter { $0.phase == .ready || $0.phase == .playing }.count
            return HubRole(id: "home", title: String(localized: "Home"), systemImage: "house",
                tone: failures > 0 ? .error : playing > 0 ? .ok : .todo,
                status: failures > 0 ? String(localized: "Some video sources need attention")
                    : playing > 0 ? String(localized: "Sending video") : String(localized: "Video sources"),
                detail: String(localized: "\(ready) responding · \(failures) unavailable · open Home to watch"),
                action: .init(title: String(localized: "Check cameras"), section: .cameras))
        }
        #endif

        switch s.hapStatus {
        case .running(_, _, let count):
            return HubRole(id: "home", title: String(localized: "Home"), systemImage: "house", tone: .ok,
                           status: String(localized: "Active"),
                           detail: String(localized: "\(count) accessories in the Home app · doorbells chime on HomePods"),
                           action: .init(title: String(localized: "Pairing code"), section: .sensors))
        case .stopped:
            return HubRole(id: "home", title: String(localized: "Home"), systemImage: "house", tone: .todo,
                           status: String(localized: "To turn on"),
                           detail: homeOffDetail,
                           action: .init(title: String(localized: "Pair with Home"), section: .sensors))
        case .error:
            return HubRole(id: "home", title: String(localized: "Home"), systemImage: "house", tone: .error,
                           status: String(localized: "Error"),
                           detail: String(localized: "The HomeKit bridge could not start."),
                           action: .init(title: String(localized: "See details"), section: .sensors))
        }
    }

    private static var homeOffDetail: String {
        #if LUMEN_HUB
        String(localized: "Cameras, sensors and doorbells in the Home app and on your HomePods.")
        #else
        String(localized: "Motion sensors and doorbells in the Home app and on your HomePods.")
        #endif
    }

    @MainActor private static func alerts(_ s: BridgeState) -> HubRole {
        let active = s.zoneAlerts.filter(\.enabled)
        guard !active.isEmpty else {
            return HubRole(id: "alerts", title: String(localized: "Smart alerts"), systemImage: "bell", tone: .todo,
                           status: String(localized: "No alert"),
                           detail: String(localized: "Mailbox, gate, front door… be told when a stranger passes."),
                           action: .init(title: String(localized: "Add an alert"), section: .zoneAlerts))
        }
        let summary = active.prefix(2).map { alert -> String in
            if let last = s.lastZoneVisits[alert.id] {
                return "\(alert.name) · \(last.formatted(date: .omitted, time: .shortened))"
            }
            return String(localized: "\(alert.name) · quiet")
        }.joined(separator: " — ")
        return HubRole(id: "alerts", title: String(localized: "Smart alerts"), systemImage: "bell", tone: .ok,
                       status: String(localized: "\(active.count) active"), detail: summary,
                       action: .init(title: String(localized: "Manage"), section: .zoneAlerts))
    }
}

/// Window root: the « Accueil » by default, the sidebar settings on demand.
struct HubRootView: View {
    @Bindable var state: BridgeState
    var onSetup: () -> Void
    let mainWindow: () -> MainWindow
    @AppStorage("lumenbridge.window.showsSettings") private var showsSettings = false
    @AppStorage("lumenbridge.mainwindow.section") private var sectionRaw: String = MainWindow.Section.status.rawValue

    var body: some View {
        Group {
            if showsSettings {
                mainWindow()
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                showsSettings = false
                            } label: {
                                Label("Home", systemImage: "chevron.backward")
                            }
                            .help(String(localized: "Back to the home screen"))
                        }
                    }
            } else {
                HubHomeView(state: state, onSetup: onSetup) { section in
                    sectionRaw = section.rawValue
                    showsSettings = true
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        // Dock icon while the window is open (a menu-bar app is otherwise
        // invisible in the Dock and ⌘-Tab), hidden again when it closes.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct HubHomeView: View {
    @Bindable var state: BridgeState
    var onSetup: () -> Void
    var open: (MainWindow.Section) -> Void

    private var roles: [HubRole] { HubRole.all(from: state) }

    private var headline: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 18 ? String(localized: "Hello") : String(localized: "Good evening")
        let issues = roles.filter { $0.tone == .todo || $0.tone == .error }
        if roles.contains(where: { $0.id == "frigate" && $0.tone != .ok }) {
            return String(localized: "Frigate is not connected yet")
        }
        if issues.isEmpty { return String(localized: "\(greeting), all is well") }
        return issues.count == 1
            ? String(localized: "\(greeting), one thing to set up")
            : String(localized: "\(greeting), \(issues.count) things to set up")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline)
                            .font(.system(size: 34, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(HubPalette.ink)
                        Text("Your Mac connects Frigate to all your Apple devices. It keeps running in the background, even with this window closed.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Guided setup", action: onSetup)
                            .buttonStyle(HubActionStyle())
                        Button(String(localized: "Advanced settings")) { open(.status) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.regular)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(roles) { role in
                        HubRoleCard(role: role) { if let action = role.action { open(action.section) } }
                    }
                }
                HubAvailabilitySettings()
            }
            .padding(.horizontal, 56)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(HubPalette.panel)
    }
}

struct HubRoleCard: View {
    let role: HubRole
    var onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HubPalette.tile(role.tone))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: role.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HubPalette.text(role.tone))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(role.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(HubPalette.ink)
                    Spacer(minLength: 8)
                    Text(role.status).font(.system(size: 12, weight: .semibold)).foregroundStyle(HubPalette.text(role.tone))
                }
                Text(role.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = role.action, role.tone != .later {
                    Button(action: onAction) {
                        Text(action.title).font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 24)
                    }
                    .buttonStyle(HubActionStyle(prominent: role.tone != .ok))
                    .padding(.top, 8)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HubPalette.border, style: StrokeStyle(lineWidth: 1.5, dash: role.tone == .later ? [6, 4] : []))
        )
        .accessibilityElement(children: .combine)
    }
}
