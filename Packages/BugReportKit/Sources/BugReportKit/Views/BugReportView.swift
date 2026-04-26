import SwiftUI

/// Top-level entry point for the bug report flow. Routes to the AI-powered
/// conversational v2 on iOS 26+ devices that have Apple Intelligence
/// available, otherwise falls back to the v1 static form.
///
/// Usage from a host app's Settings view:
///
///     NavigationLink {
///         BugReportView(provider: LumenBugReportContext())
///     } label: { Label("Report a Bug", systemImage: "ant.fill") }
public struct BugReportView: View {
    let provider: any BugReportContextProvider

    public init(provider: any BugReportContextProvider) {
        self.provider = provider
    }

    public var body: some View {
        if #available(iOS 26, macOS 26, visionOS 26, *), BugTriageService.aiIsAvailable {
            BugReportConversationView(provider: provider)
        } else {
            BugReportFormView(provider: provider)
        }
    }
}
