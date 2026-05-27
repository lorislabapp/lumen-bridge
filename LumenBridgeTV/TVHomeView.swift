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
    /// Closure that re-runs the coordinator's start path — re-probes
    /// MQTT, refreshes CloudKit account status, re-runs Bonjour discovery.
    /// Wired by `LumenBridgeTVApp` to `coordinator.start()`.
    var onRefresh: () async -> Void = {}
    /// Closure that fires a synthetic CloudKit event through the bridge
    /// pipeline so reviewers (and users debugging setup) can see counters
    /// increment without waiting for a real Frigate detection. Wired
    /// by `LumenBridgeTVApp` to `coordinator.sendTestEvent()`.
    var onSendTestEvent: () async -> Void = {}

    @State private var isRefreshing = false
    @State private var isSendingTest = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.06, green: 0.06, blue: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                foregroundOnlyBanner

                header

                HStack(spacing: 32) {
                    Button {
                        triggerRefresh()
                    } label: {
                        statusCard(
                            title: "Frigate",
                            systemImage: "video.fill",
                            primary: frigatePrimary,
                            secondary: frigateSecondary,
                            healthy: state.mqttConnected
                        )
                    }
                    .buttonStyle(.card)

                    Button {
                        triggerRefresh()
                    } label: {
                        statusCard(
                            title: "CloudKit",
                            systemImage: "icloud.fill",
                            primary: state.cloudKitStatus.humanReadable,
                            secondary: cloudKitEventsSecondary,
                            healthy: state.cloudKitStatus.isHealthy
                        )
                    }
                    .buttonStyle(.card)
                }

                eventsStrip

                actionRow
            }
            .padding(.horizontal, 96)
        }
    }

    /// Two focusable buttons shown below the status cards. They give
    /// the Siri Remote something to navigate to beyond the cards and
    /// also give app-review verifiers a one-press way to see the
    /// pipeline in motion (counters increment, statuses re-probe).
    private var actionRow: some View {
        HStack(spacing: 24) {
            Button {
                triggerSendTestEvent()
            } label: {
                Label(
                    isSendingTest ? "Sending…" : "Send test event",
                    systemImage: isSendingTest ? "hourglass" : "bolt.fill"
                )
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
            .disabled(isSendingTest || !state.cloudKitStatus.isHealthy)

            Button {
                triggerRefresh()
            } label: {
                Label(
                    isRefreshing ? "Refreshing…" : "Refresh",
                    systemImage: isRefreshing ? "hourglass" : "arrow.clockwise"
                )
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
            .disabled(isRefreshing)
        }
        .padding(.top, 8)
    }

    private func triggerRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await onRefresh()
            isRefreshing = false
        }
    }

    private func triggerSendTestEvent() {
        guard !isSendingTest else { return }
        isSendingTest = true
        Task {
            await onSendTestEvent()
            isSendingTest = false
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
        return "Waiting for config from your Mac…"
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
        VStack(spacing: 18) {
            if state.frigateHost == nil {
                Text("Open Lumen Bridge on your Mac and finish the setup wizard there. Your Apple TV will pick up the Frigate connection automatically via iCloud.")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            } else {
                Text("Leave this running — the bridge forwards Frigate events to all your Lumen devices via iCloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            // Operational note for Apple TV deployments. tvOS suspends
            // the foreground app when the user switches to another one
            // (Netflix, etc.), so the Bridge has to stay foreground for
            // the relay to keep running. HDMI standby (TV "off") doesn't
            // affect this — the Apple TV box stays alive on the network.
            tvOperationalNote
        }
    }

    /// Top-of-screen orange banner that flags the foreground-only
    /// limitation up-front, so users (and App Store reviewers) see it
    /// the moment the app launches rather than scrolling to a footer.
    /// tvOS does not allow long-running background work, so the
    /// honest framing is "best-effort while in foreground; for 24/7,
    /// run the macOS Bridge or Linux Bridge". This banner says exactly
    /// that without burying the lede.
    private var foregroundOnlyBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Foreground only")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Apple TV pauses background apps. Lumen Bridge keeps relaying events while this app stays foreground (screen off is fine). Switching to Netflix or Apple TV+ suspends the bridge until you reopen it. For 24/7 operation, run Lumen Bridge for macOS or the Linux Docker container alongside Frigate — they take over automatically.")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.orange.opacity(0.6), lineWidth: 2)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Footer that explains the only thing about Apple TV deployments
    /// that surprises users: the Bridge runs as long as Lumen Bridge
    /// is the foreground tvOS app — including with the screen off
    /// (HDMI standby). Switching to Netflix / Apple TV+ etc. will
    /// suspend us. Phrased to be reassuring (the common case works)
    /// while flagging the one gotcha.
    private var tvOperationalNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.callout)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("Always-on tip")
                    .font(.callout.weight(.semibold))
                Text("The bridge keeps running even when your TV is off — the Apple TV box stays awake on Wi-Fi. Just don't switch to another app on the Apple TV (Netflix, Apple TV+, etc.); tvOS will suspend the bridge until you reopen it. A dedicated Apple TV with Lumen Bridge as the home app is the most reliable setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1200, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
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
