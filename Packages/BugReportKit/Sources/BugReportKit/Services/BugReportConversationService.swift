import Foundation
import os
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "fr.lorislab.bugreportkit", category: "Conversation")

// MARK: - Message model

/// One turn in the bug-report conversation.
public enum BugReportMessage: Identifiable, Equatable, Sendable {
    case user(id: UUID = UUID(), text: String)
    case assistant(id: UUID = UUID(), text: String)
    case tool(id: UUID = UUID(), toolName: String, summary: String)

    public var id: UUID {
        switch self {
        case .user(let id, _), .assistant(let id, _), .tool(let id, _, _):
            return id
        }
    }
}

// MARK: - Conversation state

@available(iOS 26, macOS 26, visionOS 26, *)
@MainActor
@Observable
public final class BugReportConversationService {

    public private(set) var messages: [BugReportMessage] = []
    public private(set) var isThinking: Bool = false
    public private(set) var triageOutcome: BugTriage?
    public private(set) var lastError: String?

    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    private let provider: any BugReportContextProvider
    private let domainAddendum: String

    // MARK: Lifecycle

    public init(provider: any BugReportContextProvider) {
        self.provider = provider
        self.domainAddendum = provider.domainSystemPromptAddendum
        bootstrapSession()
        seedGreeting()
    }

    private func bootstrapSession() {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, visionOS 26, *) else { return }

        // Combine the package's generic tools with the host's domain tools.
        // Generic ones (`GetDeviceContextTool`, `QueryConnectionLogTool`)
        // are shipped by hosts via the provider for now until we promote
        // them into the package — keeps the package free of platform
        // imports today.
        let tools = provider.domainTools
        let instructions = Self.buildInstructions(domainAddendum: domainAddendum)
        session = LanguageModelSession(tools: tools, instructions: { instructions })
        #endif
    }

    private func seedGreeting() {
        let greeting = String(localized: "Hi! I'm here to help report a bug. Tell me what's not working in your own words — I'll figure out what diagnostic info to attach.")
        messages.append(.assistant(text: greeting))
    }

    // MARK: User input

    public func send(userInput: String) async {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(.user(text: trimmed))
        await respond(to: trimmed)
    }

    /// Forces an early wrap-up: tells the model we have enough info, please
    /// emit the final structured triage. UI exposes this as "Generate Report
    /// Now" if the conversation drags on.
    public func requestEarlyFinalize() async {
        await respond(to: """
        I have enough context. Please respond now with ONLY the final triage as a JSON object \
        on a single line, prefixed with the literal string `TRIAGE:` — no other words. \
        Schema: {"category": "<category>", "severity": "<severity>", "infoNeeded": [<fields>], "suggestedFollowUp": null}.
        """)
    }

    // MARK: Internal — turn execution

    private func respond(to userText: String) async {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, visionOS 26, *), let session else {
            messages.append(.assistant(text: String(localized: "Apple Intelligence is unavailable on this device.")))
            return
        }
        isThinking = true
        defer { isThinking = false }
        do {
            let response = try await session.respond(to: userText)
            let content = response.content
            if let triage = Self.tryParseTerminalTriage(content) {
                triageOutcome = triage
                let confirmation = String(localized: "I've got everything I need. Tap Generate Report below — I'll attach only the relevant bits.")
                messages.append(.assistant(text: confirmation))
            } else {
                messages.append(.assistant(text: content))
            }
        } catch {
            logger.error("Foundation Models conversation error: \(error.localizedDescription)")
            lastError = error.localizedDescription
            messages.append(.assistant(text: String(localized: "Hit a snag thinking that through. Want to retry?")))
        }
        #else
        messages.append(.assistant(text: String(localized: "Apple Intelligence is unavailable on this device.")))
        #endif
    }

    /// Looks for `TRIAGE: {...}` markers, which the model emits when it
    /// decides it has enough context to wrap up. Tolerates markdown fences
    /// and extra whitespace because models are creative about formatting.
    public static func tryParseTerminalTriage(_ raw: String) -> BugTriage? {
        let lines = raw.split(separator: "\n").map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("triage:") else { continue }
            var json = String(trimmed.dropFirst("triage:".count))
            json = json.replacingOccurrences(of: "```json", with: "")
            json = json.replacingOccurrences(of: "```", with: "")
            json = json.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = json.data(using: .utf8) else { continue }
            if let triage = try? JSONDecoder().decode(BugTriage.self, from: data) {
                return triage
            }
        }
        return nil
    }

    // MARK: Bundle generation

    /// Asks the host to produce its diagnostic bundle, passing along the
    /// chat transcript so the host can include it (Lumen writes it to the
    /// zip alongside the JSON logs).
    public func generateBundle() async -> URL? {
        let transcript = renderTranscript()
        return await provider.generateBundle(transcript: transcript)
    }

    /// Markdown summary of the chat — what the developer reads first when
    /// triaging the report.
    public func renderTranscript() -> String {
        var out: [String] = []
        out.append("# Bug Report — Conversation transcript")
        out.append("")
        out.append("_Generated \(ISO8601DateFormatter().string(from: Date()))_")
        out.append("")
        if let triage = triageOutcome {
            out.append("**Category:** \(triage.category.displayName)")
            out.append("**Severity:** \(triage.severity.emoji) \(triage.severity.displayName)")
            out.append("")
        }
        for msg in messages {
            switch msg {
            case .user(_, let text):
                out.append("**User:** \(text)")
            case .assistant(_, let text):
                out.append("**Assistant:** \(text)")
            case .tool(_, let name, let summary):
                out.append("_Tool · `\(name)` → \(summary)_")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: System prompt
    //
    // The "retraining-equivalent" lever: editing the rules + examples here
    // shapes the model's behavior without touching code. Hosts can append
    // their own framing via `BugReportContextProvider.domainSystemPromptAddendum`.

    private static let baseInstructions = """
    You are an on-device bug triager. You help a single user describe a problem
    in an iOS app, then you produce a well-structured triage that the developer
    can act on.

    YOUR STYLE:
    - Warm, concise, never robotic. One short paragraph at a time.
    - Never ask for information your tools can fetch. ALWAYS call a tool first.
    - Never demand technical detail the user can't reasonably know off the top of their head.
    - When you're not sure, ask ONE clarifying question per turn — never a checklist.
    - Stop the conversation as soon as you have enough to triage. Don't pad.

    TOOL-CALLING RULES:
    - Use any tools the host provides, autonomously, without narrating each call.
    - Call tools BEFORE asking the user — the answer is almost always already in the data.
    - Report back to the user only when you have a clarifying question or the final triage.

    YOUR FINAL OUTPUT:
    When you have enough context to triage, emit on its own line:

    TRIAGE: {"category": "<one of: streaming, auth, notifications, recordings, events, ui, watch, widgets, other>", "severity": "<one of: critical, major, minor, question>", "infoNeeded": [<a subset of: appBuild, osVersion, deviceModel, frigateVersion, authMode, connectionScheme, lastApiCallStatus, isCellular, relayVersion, mqttConfigured, lastWorkingDate, reproSteps, affectedCameras, proxySetup, attachScreenshot>], "suggestedFollowUp": null}

    The TRIAGE line MUST start with the literal string "TRIAGE:" so the host app can detect it.
    Do not output the TRIAGE line until you have actually called the relevant tools.
    """

    private static func buildInstructions(domainAddendum: String) -> String {
        if domainAddendum.isEmpty { return baseInstructions }
        return baseInstructions + "\n\nABOUT THIS APP:\n" + domainAddendum
    }
}
