import AVFoundation
import Foundation

/// Decodes the audio track of a Frigate clip (MP4/AAC, or any AVFoundation
/// container) to 16 kHz mono Float32. AVAssetReader does the resampling and
/// downmix, so no hand-parsing of PCM bytes happens anywhere.
public enum AudioDecoder {
    /// Longest clip we accept (speech events are seconds to a few minutes).
    public static let defaultMaxDuration: TimeInterval = 15 * 60

    public static func decode16kMono(url: URL, maxDuration: TimeInterval = defaultMaxDuration) async throws -> PCMAudio {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw HearingError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds
        if duration.isFinite, duration > maxDuration { throw HearingError.audioTooLong }
        return try readSamples(asset: asset, tracks: tracks, maxDuration: maxDuration)
    }

    private static func readSamples(asset: AVURLAsset, tracks: [AVAssetTrack], maxDuration: TimeInterval) throws -> PCMAudio {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw HearingError.decodeFailed }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: PCMAudio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw HearingError.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw HearingError.decodeFailed }
        defer { reader.cancelReading() }

        let limit = Int(maxDuration * PCMAudio.sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(min(limit, Int(PCMAudio.sampleRate) * 60))
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
            guard status == kCMBlockBufferNoErr else { throw HearingError.decodeFailed }
            if samples.count > limit { throw HearingError.audioTooLong }
        }
        guard reader.status == .completed else { throw HearingError.decodeFailed }
        return PCMAudio(samples: samples)
    }
}
