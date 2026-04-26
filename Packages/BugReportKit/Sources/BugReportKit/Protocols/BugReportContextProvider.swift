import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Contract a host application implements to plug its domain into BugReportKit.
///
/// The package supplies the orchestration (chat-style conversation, multi-turn
/// LanguageModelSession, fallback keyword classifier, sanitization, the user
/// interface). The host supplies:
///
///   • `connectionLog`        — its HTTP request log, normalized
///   • `domainTools`          — Foundation Models `Tool`s specific to the host's
///                              domain (e.g. `GetFrigateContextTool` in Lumen,
///                              `GetCloudKitContextTool` in Clasp)
///   • `theme`                — colors / fonts so the host's design language
///                              flows through the bug report flow
///   • `generateBundle`       — produces the final shareable diagnostic zip;
///                              hosts already have one of these from before
///                              they adopted BugReportKit (Lumen's
///                              `DiagnosticBundle.generate`, etc.)
///
/// Adoption looks like:
///
///     struct LumenBugReportContext: BugReportContextProvider {
///         let connectionLog: any ConnectionLogProvider = LumenConnectionLog()
///         let theme: any BugReportTheme = LumenTheme()
///         @available(iOS 26, macOS 26, visionOS 26, *)
///         var domainTools: [any Tool] {
///             [GetFrigateContextTool(...), GetActiveSettingsTool(...)]
///         }
///         func generateBundle(transcript: String?) async -> URL? {
///             await DiagnosticBundle.generate(...)
///         }
///     }
@MainActor
public protocol BugReportContextProvider {

    /// Host's HTTP request log, normalized to the package's `ConnectionLogEntryShape`.
    /// Used by the package's built-in `QueryConnectionLogTool` so the host doesn't
    /// have to re-implement filtering / sanitization for the AI to see its log.
    var connectionLog: any ConnectionLogProvider { get }

    /// Host-specific Foundation Models tools. Combined with the package's two
    /// generic tools (`GetDeviceContextTool`, `QueryConnectionLogTool`) before
    /// being handed to the LanguageModelSession.
    ///
    /// Available only on iOS 26+/macOS 26+/visionOS 26+ because the `Tool`
    /// protocol itself ships with Foundation Models (iOS 26).
    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, visionOS 26, *)
    var domainTools: [any Tool] { get }
    #endif

    /// Visual theme — colors and fonts. Defaults to Apple system styling if the
    /// host doesn't override (`DefaultBugReportTheme`).
    var theme: any BugReportTheme { get }

    /// Domain-specific system-prompt addendum. The package provides the spine of
    /// the prompt (style, tool-use rules, termination contract). The host appends
    /// short text describing what app the user is in so the model uses the right
    /// vocabulary. E.g. Lumen returns "You are inside Lumen for Frigate, a
    /// SwiftUI Frigate NVR companion app." Defaults to empty.
    var domainSystemPromptAddendum: String { get }

    /// The host's existing diagnostic bundle generator. Returns a `URL` to a
    /// shareable file (zip/tar/pdf — whatever the host produces). The package
    /// passes the conversation transcript so the host can include it inside.
    /// Returning `nil` surfaces a "couldn't bundle" error to the user.
    func generateBundle(transcript: String?) async -> URL?
}

public extension BugReportContextProvider {
    /// Default: no additional host-specific framing. Hosts that want better
    /// triage accuracy override this to give the model app context.
    var domainSystemPromptAddendum: String { "" }

    /// Default theme — Apple system-styled, looks fine on iOS/macOS without
    /// any host customization.
    var theme: any BugReportTheme { DefaultBugReportTheme() }
}
