import Foundation
import LorisReports
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Lumen Bridge's `LorisReports` (LorisLabsKit) adoption. Generated 2026-04-26 then
/// hand-tuned with Bridge-specific framing (it's a niche app — the
/// model needs the context to triage correctly).
///
/// The diagnostic bundle includes the live BridgeState snapshot
/// (MQTT/CloudKit/HAP/Homebridge status + event counters), the
/// CloudKit container, the resolved Frigate host, and the user's
/// current toggles. That's enough for most "events not arriving on
/// my iPhone" or "HomeKit not pairing" reports without further
/// back-and-forth.
@MainActor
struct LumenBridgeBugReportContext: BugReportContextProvider {

    static func redactDiagnosticText(_ value: String) -> String {
        var text = ReportRedactionPipeline().redact(value)
        for pattern in [#"(?i)\b(?:https?|rtsps?|srtp|wss?|mqtts?|x-hm)://[^\s<>]+"#,
                        #"\b[0-9]{3}-[0-9]{2}-[0-9]{3}\b"#,
                        #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#,
                        #"(?i)\b(?:[0-9a-f]{0,4}:){2,}[0-9a-f:%_.-]+"#,
                        #"(?i)-srtp_out_params\s+[^\s]+"#,
                        #"(?i)\b[a-z0-9][a-z0-9.-]*\.(?:local|ts\.net)\b"#] {
            text = text.replacingOccurrences(of: pattern, with: "[PRIVATE DATA OMITTED]", options: .regularExpression)
        }
        return text
    }

    /// Captured at construction time — the bug report flow runs in a
    /// modal and we want a stable snapshot, not a live binding.
    let stateSnapshot: BridgeStateSnapshot

    init(state: BridgeState? = nil) {
        self.stateSnapshot = BridgeStateSnapshot(state: state)
    }

    var connectionLog: any ConnectionLogProvider {
        // Bridge talks MQTT + CloudKit, no HTTP request log to expose.
        EmptyConnectionLogProvider()
    }

    var theme: any BugReportTheme {
        DefaultBugReportTheme()
    }

    var domainSystemPromptAddendum: String {
        """
        You are inside Lumen Bridge — a macOS / tvOS app that subscribes \
        to a Frigate NVR's MQTT broker and fans events out to the user's \
        private CloudKit database for the Lumen for Frigate iOS app to \
        render. It also exposes Frigate cameras as HomeKit accessories \
        via Bouke/HAP (motion sensors) and a Homebridge sidecar (camera \
        streaming, macOS direct-download builds only).

        The most common failure modes:
        • MQTT connection drops or never connects (firewall, wrong \
          host/port, auth, broker on a different VLAN).
        • iCloud account issues — Bridge requires the user to be signed \
          in to iCloud on the host Mac/Apple TV.
        • CloudKit schema not promoted to PRODUCTION (Apple gates this — \
          requires a Console click; the Bridge cannot do it via API).
        • HomeKit pairing — code typo, accessory already paired to a \
          different Home, network discovery (Bonjour) blocked.
        • HomeKit Cameras (Homebridge) — sandbox prevents subprocess on \
          MAS builds; npm not installed; Frigate web URL not configured.
        • No events being received — Frigate not publishing to MQTT, \
          topic prefix mismatch, or events filtered by stationary flag.

        Use the bundled BridgeState snapshot (MQTT host, CloudKit status, \
        HAP/Homebridge state, event counters) to triage. Don't ask the \
        user to re-state things the snapshot already shows.
        """
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, visionOS 26, *)
    var domainTools: [any FoundationModels.Tool] {
        []
    }
    #endif

    func generateBundle(transcript: String?) async -> URL? {
        var lines: [String] = []
        lines.append("# Lumen Bridge — Bug Report")
        lines.append("")
        lines.append("**Sent:** \(ISO8601DateFormatter().string(from: Date()))")
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            lines.append("**App:** Lumen Bridge \(v) (build \(b))")
        }
        #if os(macOS)
        lines.append("**Platform:** macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #elseif os(tvOS)
        lines.append("**Platform:** tvOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #endif
        lines.append("")

        lines.append("## State")
        lines.append("- **MQTT connected:** \(stateSnapshot.mqttConnected)")
        if stateSnapshot.frigateHost != nil, stateSnapshot.frigatePort != nil {
            lines.append("- **Frigate broker:** configured (address omitted)")
        } else {
            lines.append("- **Frigate broker:** not configured")
        }
        if stateSnapshot.lastMQTTError != nil {
            lines.append("- **Last MQTT error:** present (details omitted)")
        }
        lines.append("- **CloudKit:** \(stateSnapshot.cloudKitStatus)")
        lines.append("- **CloudKit container:** iCloud.com.lorislabapp.lumenbridge")
        lines.append("- **Events received:** \(stateSnapshot.eventsReceived)")
        lines.append("- **Events forwarded:** \(stateSnapshot.eventsForwarded)")
        if let last = stateSnapshot.lastEventAt {
            lines.append("- **Last event:** \(ISO8601DateFormatter().string(from: last))")
        }
        lines.append("- **HAP (HomeKit sensors):** \(stateSnapshot.hapStatusDescription)")
        lines.append("- **Homebridge (HomeKit cameras):** \(stateSnapshot.homebridgeStatusDescription)")
        lines.append("")

        lines.append("## Toggles")
        let defaults = UserDefaults.standard
        lines.append("- **Clip upload:** \(defaults.bool(forKey: "lumenbridge.clip_upload_enabled"))")
        lines.append("- **HAP enabled:** \(defaults.bool(forKey: "lumenbridge.hap.enabled"))")
        #if os(macOS)
        lines.append("- **Homebridge enabled:** \(defaults.bool(forKey: "lumenbridge.homebridge.cameras_enabled"))")
        if let webURL = defaults.string(forKey: "lumenbridge.homebridge.frigate_web_url"), !webURL.isEmpty {
            lines.append("- **Frigate web URL:** configured (address omitted)")
        }
        #endif
        lines.append("")

        if let transcript, !transcript.isEmpty {
            lines.append("## Conversation")
            lines.append("")
            lines.append(transcript)
        }

        let content = Self.redactDiagnosticText(lines.joined(separator: "\n"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumenbridge-bug-report-\(Int(Date().timeIntervalSince1970)).md")
        do {
            try content.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Frozen copy of `BridgeState` so the bundle reflects what the user
/// saw when they opened the report flow, not a moving target. Wraps
/// the platform-specific Homebridge state behind a string description
/// so this struct itself stays cross-platform.
struct BridgeStateSnapshot: Sendable {
    let mqttConnected: Bool
    let frigateHost: String?
    let frigatePort: Int?
    let lastMQTTError: String?
    let eventsReceived: Int
    let eventsForwarded: Int
    let lastEventAt: Date?
    let cloudKitStatus: String
    let hapStatusDescription: String
    let homebridgeStatusDescription: String

    @MainActor
    init(state: BridgeState?) {
        self.mqttConnected = state?.mqttConnected ?? false
        self.frigateHost = state?.frigateHost == nil ? nil : "configured"
        self.frigatePort = state?.frigatePort
        self.lastMQTTError = state?.lastMQTTError == nil ? nil : "error present"
        self.eventsReceived = state?.eventsReceived ?? 0
        self.eventsForwarded = state?.eventsForwarded ?? 0
        self.lastEventAt = state?.lastEventAt
        self.cloudKitStatus = state?.cloudKitStatus.isHealthy == true ? "available" : "not available"

        switch state?.hapStatus ?? .stopped {
        case .stopped: self.hapStatusDescription = "stopped"
        case .running(_, _, let count): self.hapStatusDescription = "running (\(count) accessories)"
        case .error: self.hapStatusDescription = "error (details omitted)"
        }

        #if os(macOS)
        switch state?.homebridgeStatus ?? .stopped {
        case .stopped: self.homebridgeStatusDescription = "stopped"
        case .running: self.homebridgeStatusDescription = "running (pairing code omitted)"
        case .error: self.homebridgeStatusDescription = "error (details omitted)"
        }
        #else
        self.homebridgeStatusDescription = "not available on this platform"
        #endif
    }
}
