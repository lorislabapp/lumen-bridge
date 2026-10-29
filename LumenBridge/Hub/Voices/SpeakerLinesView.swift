#if LUMEN_HUB
import LumenHearing
import SwiftUI

/// Transcript lines with their speaker: "S1", "Marie", "Marie?", "Unknown voice #3".
/// Names come from the voice database at display time, so "forget me"
/// removes them everywhere at once.
struct SpeakerLinesView: View {
    let record: TranscriptRecord
    let voices: VoiceService

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(record.segments.enumerated()), id: \.offset) { _, segment in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let speaker = segment.speaker {
                        let label = voices.labels[record.eventID]?[speaker]
                        Text(voices.display(label, speaker: speaker))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(label?.band))
                            .frame(minWidth: 52, alignment: .leading)
                    }
                    Text(segment.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func color(_ band: VoiceBand?) -> Color {
        switch band {
        case .match?, .confirmed?: return .accentColor
        case .maybe?: return .orange
        default: return .secondary
        }
    }
}
#endif
