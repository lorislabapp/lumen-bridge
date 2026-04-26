import SwiftUI

/// V2 chat-style bug report flow powered by Apple Intelligence + tool
/// calling. Shown by `BugReportView` when the device runs iOS/macOS/visionOS
/// 26+ with `SystemLanguageModel` available; otherwise `BugReportFormView`
/// is used.
@available(iOS 26, macOS 26, visionOS 26, *)
public struct BugReportConversationView: View {
    let provider: any BugReportContextProvider

    @Environment(\.dismiss) private var dismiss

    @State private var conversation: BugReportConversationService?
    @State private var draft: String = ""
    @State private var isGeneratingBundle = false
    @State private var bundleURL: URL?
    @State private var showShareSheet = false
    @FocusState private var inputFocused: Bool

    public init(provider: any BugReportContextProvider) {
        self.provider = provider
    }

    public var body: some View {
        let theme = provider.theme
        VStack(spacing: 0) {
            chatScroll(theme: theme)
            inputBar(theme: theme)
        }
        .background(theme.background)
        .navigationTitle("Report a Bug")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if conversation?.triageOutcome != nil {
                    Button {
                        Task { await generateBundle() }
                    } label: {
                        Label("Generate", systemImage: "doc.zipper")
                    }
                    .disabled(isGeneratingBundle)
                }
            }
        }
        .onAppear {
            if conversation == nil {
                conversation = BugReportConversationService(provider: provider)
            }
            inputFocused = true
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { bundleURL = nil }) {
            if let url = bundleURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Chat list

    @ViewBuilder
    private func chatScroll(theme: any BugReportTheme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let conversation {
                        ForEach(conversation.messages) { message in
                            messageRow(message, theme: theme)
                                .id(message.id)
                        }
                        if conversation.isThinking {
                            thinkingBubble(theme: theme)
                                .id("typing")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: conversation?.messages.count ?? 0) { _, _ in
                if let last = conversation?.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: BugReportMessage, theme: any BugReportTheme) -> some View {
        switch message {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(theme.calloutFont)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant(_, let text):
            HStack(alignment: .top) {
                avatar(theme: theme)
                Text(text)
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 40)
            }
        case .tool(_, let toolName, let summary):
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                Text("\(toolName) · \(summary)")
                    .font(theme.caption2Font)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }

    private func avatar(theme: any BugReportTheme) -> some View {
        Image(systemName: "sparkles")
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(theme.accent.opacity(0.85), in: Circle())
            .padding(.top, 2)
    }

    private func thinkingBubble(theme: any BugReportTheme) -> some View {
        HStack(alignment: .top) {
            avatar(theme: theme)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(theme.textTertiary)
                        .frame(width: 6, height: 6)
                        .opacity(0.4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
    }

    // MARK: - Input bar

    private func inputBar(theme: any BugReportTheme) -> some View {
        VStack(spacing: 0) {
            Divider().background(theme.border)
            HStack(spacing: 10) {
                TextField(String(localized: "Describe what's wrong…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(theme.textPrimary)
                    .focused($inputFocused)
                    .submitLabel(.send)

                Button {
                    Task { await sendDraft() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? theme.accent : theme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(theme.background)
    }

    private var canSend: Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return conversation?.isThinking == false
    }

    // MARK: - Actions

    private func sendDraft() async {
        let text = draft
        draft = ""
        await conversation?.send(userInput: text)
    }

    private func generateBundle() async {
        guard let conversation else { return }
        isGeneratingBundle = true
        defer { isGeneratingBundle = false }
        let url = await conversation.generateBundle()
        await MainActor.run {
            if let url {
                self.bundleURL = url
                self.showShareSheet = true
            }
        }
    }
}
