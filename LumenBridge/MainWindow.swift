import SwiftUI
import LorisReports
#if os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
#endif

/// Main settings window — a sidebar-driven control panel for everything
/// the Bridge can do. Modeled after macOS 14+ System Settings (Sequoia /
/// Tahoe). Each sidebar item is a self-contained pane that owns its own
/// form, status indicators, and actions.
///
/// Replaces the older single-form `SettingsView` once the user enables
/// any feature beyond the basic MQTT connection (HomeKit sensors,
/// HomeKit cameras, migration). Both views co-exist until we feel
/// confident the sidebar covers everything.
struct MainWindow: View {
    @Bindable var state: BridgeState
    var coordinator: BridgeCoordinator?
    var onApplyConnection: (@MainActor (_ host: String, _ port: Int, _ user: String?, _ pass: String?) async -> Void)? = nil
    var onToggleHAP: (@MainActor (_ enabled: Bool) async -> Void)? = nil
    var onToggleHomebridge: (@MainActor (_ enabled: Bool) async -> Void)? = nil
    var onSendTestEvent: (@MainActor () async -> Void)? = nil

    /// Last opened page, remembered across launches.
    @AppStorage("lumenbridge.mainwindow.section") private var sectionRaw: String = Section.status.rawValue
    private var section: Section? {
        get {
            guard let stored = Section(rawValue: sectionRaw), Section.visible.contains(stored) else { return .status }
            return stored
        }
        nonmutating set { sectionRaw = (newValue ?? .status).rawValue }
    }
    private var sectionBinding: Binding<Section?> {
        Binding(get: { section }, set: { section = $0 })
    }
    @State private var isSendingTestEvent = false

    enum Section: String, CaseIterable, Identifiable {
        case status, connection, zoneAlerts, sensors, cameras, transcription, transcripts, iCloud, logs, about
        var id: String { rawValue }

        /// HomeKit cameras (Homebridge) and speech transcription exist only in the Developer ID Hub.
        static var visible: [Section] {
            #if LUMEN_HUB
            allCases
            #else
            allCases.filter { ![.cameras, .transcription, .transcripts].contains($0) }
            #endif
        }

        var title: String {
            switch self {
            case .status:     return String(localized: "Status")
            case .connection: return String(localized: "Frigate")
            case .zoneAlerts: return String(localized: "Zone alerts")
            case .sensors:    return String(localized: "HomeKit · Sensors")
            case .cameras:    return String(localized: "HomeKit · Cameras")
            case .transcription: return String(localized: "Transcription")
            case .transcripts: return String(localized: "Transcripts")
            case .iCloud:     return String(localized: "iCloud")
            case .logs:       return String(localized: "Logs")
            case .about:      return String(localized: "About")
            }
        }

        var systemImage: String {
            switch self {
            case .status:     return "bolt.circle.fill"
            case .connection: return "video.fill"
            case .zoneAlerts: return "bell.badge.fill"
            case .iCloud:     return "icloud.fill"
            case .sensors:    return "sensor.fill"
            case .cameras:    return "video.bubble.fill"
            case .transcription: return "waveform"
            case .transcripts: return "text.bubble.fill"
            case .logs:       return "doc.text.fill"
            case .about:      return "info.circle.fill"
            }
        }
    }

    /// "Lumen Hub" (Developer ID) or "Lumen Bridge" (App Store).
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lumen Bridge"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionBinding) {
                ForEach(Section.visible) { s in
                    NavigationLink(value: s) {
                        Label(s.title, systemImage: s.systemImage)
                    }
                }
            }
            // A real macOS sidebar keeps its rows below the window buttons
            // (they used to scroll under the traffic lights).
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                switch section {
                case .status, .none: statusPane
                case .connection:    connectionPane
                case .zoneAlerts:    zoneAlertsPane
                case .iCloud:        iCloudPane
                case .sensors:       sensorsPane
                case .cameras:       camerasPane
                case .transcription: transcriptionPane
                case .transcripts:   transcriptsPane
                case .logs:          logsPane
                case .about:         aboutPane
                }
            }
            // Pinned to the top and allowed to shrink: form pages used to
            // report a min height taller than the window, which shifted the
            // whole content (sidebar included) up under the title bar.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .navigationTitle((section ?? .status).title)
            .navigationSubtitle(Self.appName)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)

    }

    // MARK: - Zone alerts pane

    @ViewBuilder private var transcriptionPane: some View {
        #if LUMEN_HUB
        HearingSettingsView(service: HearingService.shared)
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var transcriptsPane: some View {
        #if LUMEN_HUB
        TranscriptsView(service: HearingService.shared)
        #else
        EmptyView()
        #endif
    }

    private var zoneAlertsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(String(localized: "Zone alerts"),
                       String(localized: "Mailbox, gate, front door… one alert per place you want to watch."))
                .padding([.horizontal, .top], 28)
            ZoneAlertsView(state: state) { [coordinator] alerts in
                await coordinator?.setZoneAlerts(alerts)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    // MARK: - Status pane (the dashboard)

    private var statusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                paneHeader("Status",
                           String(localized: "What \(Self.appName) is doing right now."))
                statusGrid
                HStack(spacing: 12) {
                    Button {
                        guard !isSendingTestEvent else { return }
                        isSendingTestEvent = true
                        Task {
                            defer { isSendingTestEvent = false }
                            await onSendTestEvent?()
                        }
                    } label: {
                        Label("Send test event", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSendingTestEvent)
                    .help("Writes a synthetic FrigateEvent to CloudKit so you can verify the pipeline reaches your iPhone without waiting for a real detection.")

                    Button {
                        BridgeSupportWindow.shared.show(state: state)
                    } label: {
                        Label("Report a Bug", systemImage: "ant.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Open Help to contact the team, review optional diagnostics, and discover other LorisLabs apps.")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(BridgeReviewOpportunity(interactionInProgress: isSendingTestEvent))
    }

    private var statusGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]
        return LazyVGrid(columns: columns, spacing: 16) {
            statusCard(title: "Frigate MQTT",
                       value: state.mqttConnected ? "Connected" : "Disconnected",
                       detail: hostDetail,
                       healthy: state.mqttConnected)
            statusCard(title: "iCloud",
                       value: state.cloudKitStatus.humanReadable,
                       detail: String(localized: "Private iCloud database"),
                       healthy: state.cloudKitStatus.isHealthy)
            statusCard(title: "Events",
                       value: "\(state.eventsForwarded)",
                       detail: String(localized: "\(state.eventsReceived) received · \(state.eventsForwarded) forwarded"),
                       healthy: state.eventsForwarded > 0)
            statusCard(title: "HomeKit Sensors",
                       value: state.hapStatus.isRunning ? "Running" : "Off",
                       detail: hapStatusDetail,
                       healthy: state.hapStatus.isRunning)
            #if os(macOS) && LUMEN_HUB
            statusCard(title: "HomeKit Cameras",
                       value: state.homebridgeStatus.isRunning ? "Running" : "Off",
                       detail: homebridgeStatusDetail,
                       healthy: state.homebridgeStatus.isRunning)
            #endif
        }
    }

    // MARK: - Connection pane

    /// No outer ScrollView: the grouped Form scrolls on its own (two nested
    /// scroll views showed two scroll bars).
    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(String(localized: "Frigate connection"),
                       String(localized: "Where \(Self.appName) receives detection events: the same MQTT broker as your Frigate."))
                .padding([.horizontal, .top], 28)
            SettingsView(
                state: state,
                onApply: onApplyConnection,
                onSetTLS: { [coordinator] enabled in
                    await coordinator?.setMQTTUseTLS(enabled)
                }
            )
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    // MARK: - iCloud pane

    private var iCloudPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("iCloud", "Detection events live in your private CloudKit DB. Apple cannot read them.")
                statusInline(label: "Account", value: state.cloudKitStatus.humanReadable, healthy: state.cloudKitStatus.isHealthy)
                statusInline(label: "Container", value: "iCloud.com.lorislabapp.lumenbridge", healthy: true)
                if !state.cloudKitStatus.isHealthy {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    } label: {
                        Label("Open Apple ID in System Settings", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider().padding(.vertical, 4)

                Toggle("Upload MP4 clip with each event", isOn: clipUploadBinding)
                    .toggleStyle(.switch)
                Text("When enabled, the Bridge fetches the finalised clip from Frigate and attaches it to the FrigateEvent record. Clips are 1-10 MB each — leaving this off saves iCloud storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if LUMEN_HUB
                Divider().padding(.vertical, 4)

                infoBlock("Schema", """
The first FrigateEvent record auto-creates the schema in DEVELOPMENT. \
PRODUCTION promotion is web-only by Apple's design — visit the \
CloudKit Console and click 'Deploy Schema Changes'.
""", linkLabel: "Open CloudKit Console", linkURL: "https://icloud.developer.apple.com/dashboard")
                #endif
            }
            .padding(28)
        }
    }

    private var clipUploadBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "lumenbridge.clip_upload_enabled") },
            set: { UserDefaults.standard.set($0, forKey: "lumenbridge.clip_upload_enabled") }
        )
    }

    // MARK: - HomeKit Sensors pane

    private var sensorsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("HomeKit · Motion sensors",
                           "Each Frigate camera appears in Apple Home as a motion sensor. Zone alerts appear as doorbells.")
                Toggle("Enable HomeKit motion sensors", isOn: hapEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)
                switch state.hapStatus {
                case .stopped:
                    Text("Off. Toggle on to start the HAP server and pair from Apple Home.")
                        .foregroundStyle(.secondary)
                case .running(let setupCode, let setupID, let count):
                    #if os(macOS)
                    let uri = HAPBridgeManager.makeSetupURI(setupCode: setupCode, setupID: setupID)
                    pairingCodeRow(setupCode, pairingURI: uri, accessoryCount: count, prefix: Self.appName)
                    #else
                    pairingCodeRow(setupCode, pairingURI: nil, accessoryCount: count, prefix: Self.appName)
                    #endif
                case .error(let reason):
                    Text(reason).foregroundStyle(.orange)
                }
            }
            .padding(28)
        }
    }

    // MARK: - HomeKit Cameras pane

    private var camerasPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("HomeKit · Live cameras",
                           "Your Frigate cameras in Apple Home, with live view and motion. Zone alert cameras become video doorbells.")
                #if os(macOS)
                FrigateWebURLRow(coordinator: coordinator)
                if !state.cameraStatuses.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.cameraStatuses) { camera in
                            HStack(alignment: .top) {
                                Image(systemName: camera.phase == .playing ? "video.fill" : "video")
                                    .foregroundStyle(camera.phase == .unavailable ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(camera.displayName).font(.headline)
                                    Text(camera.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if camera.enabled, case .running(let code) = state.homebridgeStatus, code != "—" {
                                    Button("Copy pairing code") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code, forType: .string)
                                    }.buttonStyle(.bordered)
                                }
                            }
                        }
                        Button("Check video sources") { Task { await coordinator?.checkHomeKitCameraSources() } }
                            .disabled(coordinator == nil)
                        Text("In Home, choose Add Accessory, More Options, then select the camera by name. Your existing pairings are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Enable HomeKit cameras", isOn: homebridgeEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)
                switch state.homebridgeStatus {
                case .stopped:
                    Text("Off. The first start installs the camera module (about 1 minute).")
                        .foregroundStyle(.secondary)
                case .running(let setupCode):
                    pairingCodeRow(setupCode, pairingURI: nil, accessoryCount: nil, prefix: "Lumen Bridge Cameras")
                case .error(let reason):
                    Text(Self.cameraErrorMessage(reason)).foregroundStyle(.orange)
                }
                #else
                Text("HomeKit cameras run on the macOS Bridge. Your Apple TV inherits the Frigate connection automatically — pair the cameras from any iOS device under the same Apple ID.")
                    .foregroundStyle(.secondary)
                #endif
            }
            .padding(28)
        }
    }

    // MARK: - Logs pane

    private var logsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Logs",
                           "Detailed activity is in the Console app (subsystem com.lorislabapp.lumenbridge).")
                #if os(macOS)
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                } label: {
                    Label("Open Console.app", systemImage: "doc.text.viewfinder")
                }
                #endif
            }
            .padding(28)
        }
    }

    // MARK: - About pane

    private var aboutPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("About", String(localized: "\(Self.appName) connects Frigate to your Apple devices."))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.callout)
                Text("© 2026 LorisLabs · Christine Martin (TDV6D5L785)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 8)
                infoBlock("Privacy",
                    String(localized: "Detection events stay in your private iCloud database. Apple cannot read them. \(Self.appName) runs locally on your Mac. Optional support messages and reviewed technical diagnostics are sent to LorisLabs only after your confirmation."),
                    linkLabel: "Privacy Policy",
                    linkURL: "https://lorislab.fr/privacy.html")

                Divider().padding(.vertical, 8)

                Button {
                    BridgeSupportWindow.shared.show(state: state)
                } label: {
                    Label("Report a Bug", systemImage: "ant.fill")
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
        }
    }

    // MARK: - Helpers

    private func paneHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.title.weight(.bold))
            Text(LocalizedStringKey(subtitle)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCard(title: String, value: String, detail: String, healthy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(healthy ? .green : .orange).frame(width: 8, height: 8)
            }
            Text(LocalizedStringKey(value)).font(.title3.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusInline(label: String, value: String, healthy: Bool) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
            Circle().fill(healthy ? .green : .orange).frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }

    private func infoBlock(_ title: String, _ body: String, linkLabel: String? = nil, linkURL: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
            Text(LocalizedStringKey(body)).font(.caption).foregroundStyle(.secondary)
            if let linkLabel, let linkURL, let url = URL(string: linkURL) {
                Link(LocalizedStringKey(linkLabel), destination: url).font(.caption)
            }
        }
    }

    private func pairingCodeRow(
        _ code: String,
        pairingURI: String?,
        accessoryCount: Int?,
        prefix: String
    ) -> some View {
        HStack(alignment: .top, spacing: 20) {
            #if os(macOS)
            if let pairingURI, let qr = Self.qrImage(from: pairingURI, size: 180) {
                VStack(alignment: .center, spacing: 4) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    Text("Scan with the iOS Camera or Home app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            VStack(alignment: .leading, spacing: 6) {
                Text("Pairing code").font(.caption.weight(.semibold))
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .textSelection(.enabled)
                if let accessoryCount {
                    Text("\(accessoryCount) accessories · \(prefix)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(prefix).font(.caption).foregroundStyle(.secondary)
                }
                Text(prefix == "Lumen Bridge Cameras"
                     ? String(localized: "Open Apple Home → Add Accessory → More Options, then add each camera individually using the code above.")
                     : String(localized: "Open Apple Home → Add Accessory → \"\(prefix)\" → scan the QR code or enter the code above."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    #if os(macOS)
    /// Renders a Core Image QR code at the requested point size. Uses `.none`
    /// interpolation upstream so the crisp pixel grid survives — CIImage
    /// scaling otherwise smears the modules.
    private static func qrImage(from string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
    #endif

    private var hostDetail: String {
        if let host = state.frigateHost, let port = state.frigatePort {
            return "\(host):\(port)"
        }
        return String(localized: "Not configured")
    }

    private var hapStatusDetail: String {
        switch state.hapStatus {
        case .stopped: return String(localized: "HomeKit bridge off")
        case .running(_, _, let count): return String(localized: "\(count) HomeKit accessories")
        case .error: return String(localized: "Error — see HomeKit · Sensors")
        }
    }

    private var homebridgeStatusDetail: String {
        #if os(macOS)
        switch state.homebridgeStatus {
        case .stopped: return String(localized: "Off")
        case .running: return String(localized: "Cameras live")
        case .error(let reason):
            // Surface a recognizable hint for the most common failure modes
            // instead of the raw enum description, so the dashboard tile
            // tells the user where to look without drilling into the
            // sub-pane.
            let hint = Self.shortenHomebridgeError(reason)
            return String(localized: "Error — \(hint)")
        }
        #else
        return ""
        #endif
    }

    #if os(macOS)
    /// Maps known `HomebridgeError` cases to a short, user-facing hint.
    /// Falls back to the first 60 chars of the raw error when the case
    /// isn't recognized.
    static func cameraErrorMessage(_ raw: String) -> String {
        switch raw {
        case "frigateConfigUnreadable": return BridgeFrigateAccessError.invalidConfiguration.localizedDescription
        case "missingFrigateURL": return BridgeFrigateAccessError.invalidAddress.localizedDescription
        default: return raw
        }
    }

    private static func shortenHomebridgeError(_ raw: String) -> String {
        if raw.contains("frigateConfigUnreadable") || raw.contains("3840") {
            return String(localized: "check the Frigate address and login in HomeKit · Cameras")
        }
        if raw.contains("missingFrigateURL") {
            return String(localized: "set the Frigate web address in HomeKit · Cameras")
        }
        if raw.contains("npmNotFound") {
            return "npm not found (install Node from nodejs.org)"
        }
        if raw.contains("nodeNotFound") {
            return "node not found (install Node from nodejs.org)"
        }
        if raw.contains("installFailed") {
            return String(localized: "camera module install failed — see HomeKit · Cameras")
        }
        if raw.contains("homebridgeBinNotFound") {
            return "homebridge binary missing — re-toggle"
        }
        if raw.contains("sandbox") || raw.contains("Operation not permitted") {
            return "sandbox blocks subprocess (use direct-download build)"
        }
        let trimmed = raw.replacingOccurrences(of: "\n", with: " ")
        return String(trimmed.prefix(60))
    }
    #endif

    // Bindings — duplicate the ones from SettingsView so this pane is self-
    // contained. Once we're confident MainWindow is the canonical UI we'll
    // delete SettingsView and centralise these in BridgeCoordinator.
    private var hapEnabledBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "lumenbridge.hap.enabled") },
            set: { newValue in
                Task { @MainActor in
                    if let onToggleHAP { await onToggleHAP(newValue) }
                }
            }
        )
    }

    #if os(macOS)
    private var frigateWebURLBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "lumenbridge.homebridge.frigate_web_url") ?? "" },
            set: { UserDefaults.standard.set($0, forKey: "lumenbridge.homebridge.frigate_web_url") }
        )
    }

    private var homebridgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "lumenbridge.homebridge.cameras_enabled") },
            set: { newValue in
                Task { @MainActor in
                    if let onToggleHomebridge { await onToggleHomebridge(newValue) }
                }
            }
        )
    }
    #endif
}

#if os(macOS)
/// Authenticated API access is separate from the MQTT broker connection.
struct FrigateWebURLRow: View {
    var coordinator: BridgeCoordinator?
    @State private var text: String
    @State private var username = ""
    @State private var password = ""
    @State private var hasSavedLogin = false
    @State private var result: HomebridgeManager.FrigateCheck?
    @State private var checking = false
    private let credentialStore = BridgeFrigateCredentialStore()

    init(coordinator: BridgeCoordinator?, initialAddress: String? = nil) {
        self.coordinator = coordinator
        _text = State(initialValue: initialAddress ?? UserDefaults.standard.string(forKey: HomebridgeManager.frigateWebURLKey) ?? "")
    }

    private var normalized: String? { HomebridgeManager.normalizedWebURL(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frigate web address").font(.subheadline.weight(.semibold))
            TextField("Frigate web address", text: $text, prompt: Text("https://frigate.example.com"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { Task { await check() } }
            TextField("Frigate username (if required)", text: $username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Frigate password", text: $password,
                        prompt: Text(hasSavedLogin ? "Saved password — leave blank to keep it" : "Password"))
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit { Task { await check() } }
            Text("Use your Frigate account. The password stays in this Mac's Keychain. Leave both fields blank for an internal API without authentication.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await check() }
                } label: {
                    if checking { ProgressView().controlSize(.small) } else { Text("Test and save") }
                }
                .buttonStyle(HubActionStyle())
                .disabled(checking || normalized == nil || coordinator == nil)
                if hasSavedLogin {
                    Button("Forget saved login", role: .destructive) {
                        Task { await forget() }
                    }
                    .disabled(checking)
                }
            }
            switch result {
            case .ok(let version, let cameras):
                Label(String(localized: "Connected · Frigate \(version) · \(cameras) cameras"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let reason):
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            case nil: EmptyView()
            }
            Text("Live video uses your Frigate connection. Keep this Mac awake and connected while watching in Apple Home.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(checking)
        .task(id: normalized) {
            // Do not read the user's real Keychain when rendering offline test fixtures.
            guard coordinator != nil, let base = normalized else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let saved = try await credentialStore.load(for: base)
                guard !Task.isCancelled, normalized == base else { return }
                if username.isEmpty { username = saved?.username ?? "" }
                hasSavedLogin = saved != nil
            } catch is CancellationError { }
            catch { if normalized == base { result = .failed(BridgeFrigateEndpoint.message(for: error)) } }
        }
        .onChange(of: normalized) { _, _ in
            username = ""
            password = ""
            hasSavedLogin = false
            result = nil
        }
    }

    private func check() async {
        guard !checking, coordinator != nil, let clean = normalized else { return }
        checking = true
        defer { checking = false }
        do {
            let credentials: BridgeFrigateCredentials?
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty && !password.isEmpty {
                credentials = .init(username: user, password: password)
            } else if hasSavedLogin, password.isEmpty,
                      let saved = try await credentialStore.load(for: clean), saved.username == user {
                credentials = saved
            } else if user.isEmpty && password.isEmpty {
                credentials = nil
            } else { throw BridgeFrigateAccessError.incompleteLogin }
            let outcome = await HomebridgeManager.checkFrigate(webURL: clean, credentials: credentials)
            guard case .ok = outcome else { result = outcome; return }
            if let credentials { try await credentialStore.save(credentials, for: clean) }
            await coordinator?.setFrigateWebURL(clean)
            text = clean
            password = ""
            hasSavedLogin = credentials != nil
            result = outcome
        } catch { result = .failed(BridgeFrigateEndpoint.message(for: error)) }
    }

    private func forget() async {
        guard !checking, let base = normalized else { return }
        checking = true
        defer { checking = false }
        do {
            // Drop the active session as well as the persisted login.
            await coordinator?.setHomebridgeCamerasEnabled(false)
            try await credentialStore.remove(for: base)
            username = ""
            password = ""
            hasSavedLogin = false
            result = nil
        } catch { result = .failed(BridgeFrigateEndpoint.message(for: error)) }
    }
}
#endif
