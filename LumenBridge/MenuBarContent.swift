import SwiftUI
import AppKit

/// The menu-bar popover content. Kept dense but scannable — users glance, not
/// read. Most interactions live on the Settings window (not yet wired).
struct MenuBarContent: View {
    @Bindable var state: BridgeState
    var onSendTestEvent: (@MainActor () async -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            Divider()

            frigateSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            cloudKitSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            footer
                .padding(14)
        }
        .frame(width: 320)
    }

    // MARK: -

    private var statusColor: Color {
        if state.isConnected { return .green }
        if state.mqttConnected || state.cloudKitStatus.isHealthy { return .orange }
        return .secondary
    }

    private var statusLabel: String {
        if state.isConnected { return "Running" }
        if state.mqttConnected { return "MQTT OK, waiting on CloudKit" }
        if state.cloudKitStatus.isHealthy { return "CloudKit OK, MQTT disconnected" }
        return "Starting…"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumen Bridge")
                    .font(.headline)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var frigateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Frigate", systemImage: "video.fill")
                .font(.subheadline.weight(.semibold))

            if let host = state.frigateHost, let port = state.frigatePort {
                Text("\(host):\(port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if !state.discoveredInstances.isEmpty {
                Text("\(state.discoveredInstances.count) discovered — none paired yet")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Searching via Bonjour…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                metric(value: state.eventsReceived, label: "received")
                metric(value: state.eventsForwarded, label: "forwarded")
            }
            .padding(.top, 4)
        }
    }

    private var cloudKitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("CloudKit", systemImage: "icloud.fill")
                .font(.subheadline.weight(.semibold))
            Text(state.cloudKitStatus.humanReadable)
                .font(.caption)
                .foregroundStyle(state.cloudKitStatus.isHealthy ? Color.secondary : Color.orange)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let onSendTestEvent {
                Button {
                    Task { await onSendTestEvent() }
                } label: {
                    Label("Send test event", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .help("Writes a synthetic FrigateEvent to CloudKit. Useful for seeding the schema and verifying push delivery without a running Frigate.")
            }

            HStack {
                Button("Settings…") {
                    // TODO(0.2): open a settings window with MQTT host override,
                    // iCloud account inspector, filter rules editor.
                }
                .disabled(true)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }

    private func metric(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
