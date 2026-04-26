import SwiftUI
import BugReportKit
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

    @State private var section: Section? = .status

    enum Section: String, CaseIterable, Identifiable {
        case status      = "Status"
        case connection  = "Frigate"
        case iCloud      = "iCloud"
        case sensors     = "HomeKit · Sensors"
        case cameras     = "HomeKit · Cameras"
        case logs        = "Logs"
        case about       = "About"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .status:     return "bolt.circle.fill"
            case .connection: return "video.fill"
            case .iCloud:     return "icloud.fill"
            case .sensors:    return "sensor.fill"
            case .cameras:    return "video.bubble.fill"
            case .logs:       return "doc.text.fill"
            case .about:      return "info.circle.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { s in
                    NavigationLink(value: s) {
                        Label(s.rawValue, systemImage: s.systemImage)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .navigationTitle("Lumen Bridge")
        } detail: {
            switch section {
            case .status, .none: statusPane
            case .connection:    connectionPane
            case .iCloud:        iCloudPane
            case .sensors:       sensorsPane
            case .cameras:       camerasPane
            case .logs:          logsPane
            case .about:         aboutPane
            }
        }
        .frame(minWidth: 720, minHeight: 540)
    }

    // MARK: - Status pane (the dashboard)

    private var statusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                paneHeader("Status",
                           "What the Bridge is currently doing. Toggle features in the sidebar.")
                statusGrid
                HStack(spacing: 12) {
                    Button {
                        Task { await onSendTestEvent?() }
                    } label: {
                        Label("Send test event", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Writes a synthetic FrigateEvent to CloudKit so you can verify the pipeline reaches your iPhone without waiting for a real detection.")

                    NavigationLink {
                        BugReportView(provider: LumenBridgeBugReportContext(state: state))
                    } label: {
                        Label("Report a Bug", systemImage: "ant.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Open the AI-augmented bug-report flow. The diagnostic bundle includes the live Bridge state.")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                       detail: "Container: iCloud.com.lorislabapp.lumenbridge",
                       healthy: state.cloudKitStatus.isHealthy)
            statusCard(title: "Events",
                       value: "\(state.eventsForwarded)",
                       detail: "\(state.eventsReceived) received · \(state.eventsForwarded) forwarded",
                       healthy: state.eventsForwarded > 0)
            statusCard(title: "HomeKit Sensors",
                       value: state.hapStatus.isRunning ? "Running" : "Off",
                       detail: hapStatusDetail,
                       healthy: state.hapStatus.isRunning)
            #if os(macOS)
            statusCard(title: "HomeKit Cameras",
                       value: state.homebridgeStatus.isRunning ? "Running" : "Off",
                       detail: homebridgeStatusDetail,
                       healthy: state.homebridgeStatus.isRunning)
            #endif
        }
    }

    // MARK: - Connection pane

    private var connectionPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                paneHeader("Frigate connection",
                           "Where the Bridge subscribes to detection events. Same MQTT broker your Frigate config points at.")
                SettingsView(
                    state: state,
                    onApply: onApplyConnection,
                    onToggleHAP: nil,
                    onToggleHomebridge: nil
                )
                .padding(.top, 8)
            }
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

                Divider().padding(.vertical, 4)

                infoBlock("Schema", """
The first FrigateEvent record auto-creates the schema in DEVELOPMENT. \
PRODUCTION promotion is web-only by Apple's design — visit the \
CloudKit Console and click 'Deploy Schema Changes'.
""", linkLabel: "Open CloudKit Console", linkURL: "https://icloud.developer.apple.com/dashboard")
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
                           "Each Frigate camera appears as a HomeKit motion sensor. Native Swift HAP server (Bouke/HAP), in-process.")
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
                    pairingCodeRow(setupCode, pairingURI: uri, accessoryCount: count, prefix: "Lumen Bridge")
                    #else
                    pairingCodeRow(setupCode, pairingURI: nil, accessoryCount: count, prefix: "Lumen Bridge")
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
                           "Each Frigate go2rtc stream appears as a HomeKit camera with Live View. Powered by a private Homebridge sidecar (homebridge-camera-ffmpeg).")
                #if os(macOS)
                TextField("Frigate web URL", text: frigateWebURLBinding,
                          prompt: Text("https://frigate.local:5000"))
                Toggle("Enable HomeKit cameras", isOn: homebridgeEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)
                switch state.homebridgeStatus {
                case .stopped:
                    Text("Off. First-run install bootstraps homebridge + homebridge-camera-ffmpeg via npm (~30-90s).")
                        .foregroundStyle(.secondary)
                case .running(let setupCode):
                    pairingCodeRow(setupCode, pairingURI: nil, accessoryCount: nil, prefix: "Lumen Bridge Cameras")
                case .error(let reason):
                    Text(reason).foregroundStyle(.orange)
                }
                Divider().padding(.vertical, 4)
                Text("Distribution note: this feature requires a non-sandboxed direct-download build. The TestFlight build doesn't have permission to spawn the Homebridge subprocess.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                           "Stream the Bridge's recent activity. Open Console.app and filter by subsystem com.lorislabapp.lumenbridge for the full unified log.")
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
                paneHeader("About", "Lumen Bridge connects Frigate to Apple's ecosystem.")
                Text("Version 0.1.0 (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.callout)
                Text("© 2026 LorisLabs · Christine Martin (TDV6D5L785)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 8)
                infoBlock("Privacy",
                    "Detection events stay in your private iCloud database. Apple cannot read them. The Bridge runs locally on your Mac and never sends data to LorisLabs servers.",
                    linkLabel: "Privacy Policy",
                    linkURL: "https://lorislab.fr/privacy.html")

                Divider().padding(.vertical, 8)

                NavigationLink {
                    BugReportView(provider: LumenBridgeBugReportContext(state: state))
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
            Text(title).font(.title.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCard(title: String, value: String, detail: String, healthy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(healthy ? .green : .orange).frame(width: 8, height: 8)
            }
            Text(value).font(.title3.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusInline(label: String, value: String, healthy: Bool) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
            Circle().fill(healthy ? .green : .orange).frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }

    private func infoBlock(_ title: String, _ body: String, linkLabel: String? = nil, linkURL: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary)
            if let linkLabel, let linkURL, let url = URL(string: linkURL) {
                Link(linkLabel, destination: url).font(.caption)
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
                    Text("\(accessoryCount) accessory \(accessoryCount == 1 ? "" : "ies") · \(prefix)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(prefix).font(.caption).foregroundStyle(.secondary)
                }
                Text("Open Apple Home → Add Accessory → \"\(prefix)\" → scan the QR code or enter the code above.")
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
        return "Not configured"
    }

    private var hapStatusDetail: String {
        switch state.hapStatus {
        case .stopped: return "HAP server off"
        case .running(_, _, let count): return "\(count) sensor\(count == 1 ? "" : "s")"
        case .error: return "Error — see HomeKit · Sensors"
        }
    }

    private var homebridgeStatusDetail: String {
        #if os(macOS)
        switch state.homebridgeStatus {
        case .stopped: return "Sidecar off"
        case .running: return "Cameras live"
        case .error(let reason):
            // Surface a recognizable hint for the most common failure modes
            // instead of the raw enum description, so the dashboard tile
            // tells the user where to look without drilling into the
            // sub-pane.
            let hint = Self.shortenHomebridgeError(reason)
            return "Error — \(hint)"
        }
        #else
        return ""
        #endif
    }

    #if os(macOS)
    /// Maps known `HomebridgeError` cases to a short, user-facing hint.
    /// Falls back to the first 60 chars of the raw error when the case
    /// isn't recognized.
    private static func shortenHomebridgeError(_ raw: String) -> String {
        if raw.contains("missingFrigateURL") {
            return "set Frigate web URL in HomeKit · Cameras"
        }
        if raw.contains("npmNotFound") {
            return "npm not found (install Node from nodejs.org)"
        }
        if raw.contains("nodeNotFound") {
            return "node not found (install Node from nodejs.org)"
        }
        if raw.contains("installFailed") {
            return "homebridge install failed — see HomeKit · Cameras"
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
