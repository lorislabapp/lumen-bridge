import SwiftUI

/// Focus-based status screen for the tvOS bridge. Kept intentionally
/// minimal — this is a set-and-forget bridge, not a browsing app. The
/// primary job of this view is to show the user:
///   (a) the bridge is alive
///   (b) where the Frigate + CloudKit health stand at a glance
///   (c) a button to reset credentials / switch server if needed
///
/// The tvOS human interface guidelines encourage large, focus-friendly
/// surfaces — each status block is a card sized for 10-foot viewing.
struct TVHomeView: View {
    @Bindable var state: BridgeState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.06, green: 0.06, blue: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 48) {
                header

                HStack(spacing: 32) {
                    statusCard(
                        title: "Frigate",
                        systemImage: "video.fill",
                        primary: frigatePrimary,
                        secondary: frigateSecondary,
                        healthy: state.mqttConnected
                    )

                    statusCard(
                        title: "CloudKit",
                        systemImage: "icloud.fill",
                        primary: state.cloudKitStatus.humanReadable,
                        secondary: cloudKitEventsSecondary,
                        healthy: state.cloudKitStatus.isHealthy
                    )
                }

                eventsStrip
            }
            .padding(.horizontal, 96)
        }
    }

    // MARK: -

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Image(systemName: state.isConnected ? "bolt.circle.fill" : "bolt.slash.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(state.isConnected ? .green : .orange)
                Text("Lumen Bridge")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
            }
            Text(state.isConnected ? "Running" : "Starting up…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var frigatePrimary: String {
        if let host = state.frigateHost, let port = state.frigatePort {
            return "\(host):\(port)"
        }
        if !state.discoveredInstances.isEmpty {
            return "\(state.discoveredInstances.count) instances found"
        }
        return "Searching via Bonjour…"
    }

    private var frigateSecondary: String {
        "\(state.eventsReceived) received · \(state.eventsForwarded) forwarded"
    }

    private var cloudKitEventsSecondary: String {
        if let last = state.lastEventAt {
            let delta = Int(Date().timeIntervalSince(last))
            return "Last event \(delta)s ago"
        }
        return "No events yet"
    }

    private var eventsStrip: some View {
        HStack {
            Text("Leave this running — the bridge forwards Frigate events to all your Lumen devices via iCloud.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
    }

    private func statusCard(
        title: String,
        systemImage: String,
        primary: String,
        secondary: String,
        healthy: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(healthy ? Color.green : Color.orange)
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Circle()
                    .fill(healthy ? Color.green : Color.orange)
                    .frame(width: 14, height: 14)
            }

            Text(primary)
                .font(.title3)
                .foregroundStyle(Color.primary)
                .lineLimit(2)

            Text(secondary)
                .font(.callout)
                .foregroundStyle(Color.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}
