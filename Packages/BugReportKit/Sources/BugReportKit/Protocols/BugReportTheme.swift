import SwiftUI

/// Colors / fonts the bug report views use. Hosts can supply their design
/// language (Lumen's VigilUI dark glassmorphism, Clasp's flat light theme,
/// etc.) without BugReportKit having to depend on any host UI library.
///
/// Defaults to Apple system styling via `DefaultBugReportTheme` — looks
/// fine on iOS/macOS/visionOS without any customization.
@MainActor
public protocol BugReportTheme {
    /// Primary background of the conversation view.
    var background: Color { get }
    /// Card / bubble background color (for assistant messages, info cards).
    var cardBackground: Color { get }
    /// Slightly elevated card (severity badge background, etc.).
    var cardBackgroundElevated: Color { get }
    /// Border / divider color.
    var border: Color { get }

    /// Primary text (assistant message content, user input).
    var textPrimary: Color { get }
    /// Secondary text (subtitles, descriptions).
    var textSecondary: Color { get }
    /// Tertiary text (timestamps, hints).
    var textTertiary: Color { get }

    /// Accent — used for the user's message bubble background, primary CTAs,
    /// AI-related "sparkles" affordances.
    var accent: Color { get }
    /// Success state (e.g. report sent confirmation).
    var success: Color { get }
    /// Warning state (severity major / something looks off).
    var warning: Color { get }
    /// Critical / destructive (severity critical badge).
    var destructive: Color { get }

    /// Headline font (form section titles).
    var headlineFont: Font { get }
    /// Body / message font.
    var bodyFont: Font { get }
    /// Callout font (slightly tighter than body, used in chat bubbles).
    var calloutFont: Font { get }
    /// Caption font (metadata, hints).
    var captionFont: Font { get }
    /// Caption2 — even smaller (tool-call indicators).
    var caption2Font: Font { get }
}

/// Default Apple-system theme. Used when a host adopts BugReportKit without
/// providing its own theme. Looks correct on every platform Apple ships
/// because it uses SwiftUI's semantic / system-aware colors only.
public struct DefaultBugReportTheme: BugReportTheme {
    public init() {}

    public var background: Color { _systemBackground }
    public var cardBackground: Color { _secondarySystemBackground }
    public var cardBackgroundElevated: Color { _tertiarySystemBackground }
    public var border: Color { _separator }

    public var textPrimary: Color { .primary }
    public var textSecondary: Color { .secondary }
    public var textTertiary: Color { .secondary.opacity(0.6) }

    public var accent: Color { .accentColor }
    public var success: Color { .green }
    public var warning: Color { .orange }
    public var destructive: Color { .red }

    public var headlineFont: Font { .headline }
    public var bodyFont: Font { .body }
    public var calloutFont: Font { .callout }
    public var captionFont: Font { .caption }
    public var caption2Font: Font { .caption2 }
}

// MARK: - Cross-platform system colors
//
// SwiftUI doesn't expose `Color.systemBackground` directly cross-platform —
// UIKit has it (iOS / visionOS), AppKit names them differently. We bridge
// here so the public theme stays SwiftUI-only on every platform.

#if canImport(UIKit) && !os(watchOS)
import UIKit
private let _systemBackground = Color(uiColor: .systemBackground)
private let _secondarySystemBackground = Color(uiColor: .secondarySystemBackground)
private let _tertiarySystemBackground = Color(uiColor: .tertiarySystemBackground)
private let _separator = Color(uiColor: .separator)
#elseif canImport(AppKit)
import AppKit
private let _systemBackground = Color(nsColor: .windowBackgroundColor)
private let _secondarySystemBackground = Color(nsColor: .controlBackgroundColor)
private let _tertiarySystemBackground = Color(nsColor: .underPageBackgroundColor)
private let _separator = Color(nsColor: .separatorColor)
#else
private let _systemBackground = Color.gray.opacity(0.05)
private let _secondarySystemBackground = Color.gray.opacity(0.1)
private let _tertiarySystemBackground = Color.gray.opacity(0.15)
private let _separator = Color.gray.opacity(0.3)
#endif
