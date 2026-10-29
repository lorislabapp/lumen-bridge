#if LUMEN_HUB
import LumenHearing
import SwiftUI

/// "Transcripts" pane — local full-text search (accents and case ignored).
struct TranscriptsView: View {
    @Bindable var service: HearingService
    @State private var query = ""
    @State private var camera: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search what was said", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await refresh() } }
                Picker("Camera", selection: $camera) {
                    Text("All cameras").tag(String?.none)
                    ForEach(service.settings.cameras.keys.sorted(), id: \.self) { name in
                        Text(name.replacingOccurrences(of: "_", with: " ").capitalized).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            .padding(16)
            Divider()
            if service.transcripts.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No transcripts yet" : "No match", systemImage: "text.bubble")
                } description: {
                    Text(service.settings.enabled
                         ? "Speech heard by the cameras you turned on appears here."
                         : "Turn on transcription first, on the Transcription page.")
                }
            } else {
                List(service.transcripts) { record in
                    row(record)
                }
                .listStyle(.inset)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
        .onChange(of: camera) { Task { await refresh() } }
    }

    private func refresh() async { await service.search(query, camera: camera) }

    private func row(_ r: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(r.camera.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                Text(r.start, format: .dateTime.day().month().hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let language = r.language { Text(language.uppercased()).font(.caption2.monospaced()) }
                Text(r.engine == EngineKind.parakeetV3.rawValue ? "Parakeet" : "Apple")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(r.snippet.map(highlight) ?? AttributedString(r.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// FTS5 snippets mark matches as [word]; show them in bold.
    private func highlight(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var buffer = ""
        func flush() {
            var part = AttributedString(buffer)
            if bold { part.font = .body.bold() }
            out += part
            buffer = ""
        }
        for ch in snippet {
            if ch == "[" || ch == "]" { flush(); bold = ch == "[" } else { buffer.append(ch) }
        }
        flush()
        return out
    }
}
#endif
