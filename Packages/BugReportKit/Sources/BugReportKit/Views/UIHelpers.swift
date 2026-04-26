import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// MARK: - ThemedCard

/// Rounded glass-card the bug report views use everywhere. Background +
/// padding only — content goes inside the closure.
struct ThemedCard<Content: View>: View {
    let theme: any BugReportTheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - HeaderCard

struct HeaderCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let theme: any BugReportTheme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(theme.accent)
            Text(title)
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
            Text(subtitle)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
}

// MARK: - PrimaryButton

struct PrimaryButton: View {
    let label: String
    let icon: String
    let theme: any BugReportTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(label)
            }
            .font(theme.headlineFont)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ShareSheet

#if canImport(UIKit) && !os(watchOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
/// Cross-platform stub. On macOS the host app should provide its own share
/// flow (NSSharingService) or use the bundle URL directly. The package only
/// surfaces a "Save" affordance on non-iOS targets.
struct ShareSheet: View {
    let items: [Any]
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.up")
                .font(.largeTitle)
            Text("Sharing not yet supported on this platform from inside the package — open the bundle URL manually.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let url = items.first as? URL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}
#endif

// MARK: - Severity emoji extension (safe-bool helper)

extension BugSeverity {
    /// Convenience for compact display.
    var label: String { "\(emoji) \(displayName)" }
}
