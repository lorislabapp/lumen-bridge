import SwiftUI

/// V1 static-form fallback — used on devices that can't run Foundation Models
/// (older iOS, devices without Apple Intelligence hardware, AI disabled in
/// Settings). Three phases: describe → triage (keyword-based) → generate.
public struct BugReportFormView: View {
    let provider: any BugReportContextProvider

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case describe
        case triaging
        case followUp
        case generating
        case error
    }

    @State private var phase: Phase = .describe
    @State private var description: String = ""
    @State private var userSeverity: BugSeverity = .major
    @State private var triage: BugTriage?
    @State private var followUpAnswers: [DiagnosticField: String] = [:]
    @State private var bundleURL: URL?
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    public init(provider: any BugReportContextProvider) {
        self.provider = provider
    }

    public var body: some View {
        let theme = provider.theme
        ScrollView {
            VStack(spacing: 20) {
                switch phase {
                case .describe:    describePhase(theme: theme)
                case .triaging:    triagingPhase(theme: theme)
                case .followUp:    followUpPhase(theme: theme)
                case .generating:  generatingPhase(theme: theme)
                case .error:       errorPhase(theme: theme)
                }
            }
            .padding()
        }
        .background(theme.background)
        .navigationTitle("Report a Bug")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showShareSheet, onDismiss: { bundleURL = nil }) {
            if let url = bundleURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Phases

    private func describePhase(theme: any BugReportTheme) -> some View {
        VStack(spacing: 16) {
            HeaderCard(
                icon: "ant.fill",
                title: String(localized: "Tell us what's wrong"),
                subtitle: String(localized: "A short description in your own words. We'll figure out what diagnostic info to attach automatically."),
                theme: theme
            )

            ThemedCard(theme: theme) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                    TextField(String(localized: "e.g. live streams won't load on iPhone"), text: $description, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(4...10)
                        .foregroundStyle(theme.textPrimary)
                }
            }

            ThemedCard(theme: theme) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How serious is it?")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                    Picker("Severity", selection: $userSeverity) {
                        ForEach(BugSeverity.allCases, id: \.self) { sev in
                            Text("\(sev.emoji) \(sev.displayName)").tag(sev)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            PrimaryButton(label: String(localized: "Continue"), icon: "arrow.right.circle.fill", theme: theme) {
                Task { await runTriage() }
            }
            .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
        }
    }

    private func triagingPhase(theme: any BugReportTheme) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing your description…")
                .font(theme.bodyFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func followUpPhase(theme: any BugReportTheme) -> some View {
        VStack(spacing: 16) {
            if let triage {
                triageSummaryCard(triage, theme: theme)
                let needsInput = triage.infoNeeded.filter { !$0.isAutoFillable }
                if !needsInput.isEmpty {
                    ThemedCard(theme: theme) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("A couple of follow-ups")
                                .font(theme.headlineFont)
                                .foregroundStyle(theme.textPrimary)
                            ForEach(needsInput, id: \.self) { field in
                                if let prompt = field.userPrompt {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(prompt)
                                            .font(theme.captionFont)
                                            .foregroundStyle(theme.textSecondary)
                                        TextField("", text: Binding(
                                            get: { followUpAnswers[field] ?? "" },
                                            set: { followUpAnswers[field] = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                        }
                    }
                }
                PrimaryButton(label: String(localized: "Generate Report"), icon: "doc.zipper", theme: theme) {
                    Task { await generateBundle() }
                }
            }
        }
    }

    private func triageSummaryCard(_ triage: BugTriage, theme: any BugReportTheme) -> some View {
        ThemedCard(theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(localized: "Looks like a ") + triage.category.displayName.lowercased() + String(localized: " issue"))
                        .font(theme.headlineFont)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(triage.severity.emoji) \(triage.severity.displayName)")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.cardBackgroundElevated, in: Capsule())
                }
                if let followUp = triage.suggestedFollowUp, !followUp.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "questionmark.bubble")
                            .foregroundStyle(theme.accent)
                        Text(followUp)
                            .font(theme.calloutFont)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }

    private func generatingPhase(theme: any BugReportTheme) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Packaging diagnostic data…")
                .font(theme.bodyFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func errorPhase(theme: any BugReportTheme) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(theme.warning)
            Text("Something went wrong")
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
            if let errorMessage {
                Text(errorMessage)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(label: String(localized: "Try Again"), icon: "arrow.counterclockwise", theme: theme) {
                phase = .describe
            }
        }
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func runTriage() async {
        phase = .triaging
        let result = await BugTriageService.triage(description: description)
        await MainActor.run {
            self.triage = result
            self.phase = .followUp
        }
    }

    private func generateBundle() async {
        phase = .generating
        let summary = buildSummary()
        let url = await provider.generateBundle(transcript: summary)
        await MainActor.run {
            if let url {
                self.bundleURL = url
                self.showShareSheet = true
                self.phase = .followUp
            } else {
                self.errorMessage = String(localized: "Couldn't package the diagnostic data.")
                self.phase = .error
            }
        }
    }

    private func buildSummary() -> String {
        var out: [String] = []
        out.append("# Bug Report")
        out.append("")
        out.append("**Severity:** \(triage?.severity.emoji ?? userSeverity.emoji) \(triage?.severity.displayName ?? userSeverity.displayName)")
        if let triage {
            out.append("**Category:** \(triage.category.displayName)")
        }
        out.append("**Sent:** \(ISO8601DateFormatter().string(from: Date()))")
        out.append("")
        out.append("## Description")
        out.append(description.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("")
        if !followUpAnswers.isEmpty {
            out.append("## Follow-up answers")
            for (field, answer) in followUpAnswers where !answer.isEmpty {
                if let prompt = field.userPrompt {
                    out.append("- **\(prompt)** \(answer)")
                }
            }
        }
        return out.joined(separator: "\n")
    }
}
