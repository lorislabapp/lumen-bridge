import AVFoundation
import Foundation
import LumenHearing

// Live camera audio without ffmpeg: go2rtc (bundled in Frigate) serves each
// camera as fragmented MP4 over HTTP (`/api/go2rtc/api/stream.mp4?src=…`),
// the same stream the Bridge already opens for HomeKit. This file demuxes the
// AAC track from those fragments in memory and decodes it with AVAudioConverter
// to 16 kHz mono. Nothing is written to disk. G.711/Opus cameras need go2rtc
// to give AAC (e.g. a `#audio=aac` transcoded source) — see README.

public enum FMP4Error: Error, Equatable, Sendable {
    case noAudioTrack
    case unsupportedCodec(String)
    case malformed
    case decoderFailed
    case decoderFailedStatus(Int)
}

/// The audio track found in `moov`.
public struct FMP4AudioTrack: Sendable, Equatable {
    public var trackID: UInt32
    public var timescale: UInt32
    public var sampleRate: Double
    public var channels: UInt32
    /// AudioSpecificConfig (from `esds`), the AAC decoder's magic cookie.
    public var audioSpecificConfig: Data
    /// The whole `esds` ES_Descriptor (AudioToolbox's preferred AAC cookie).
    public var esds: Data = Data()
    public var defaultSampleSize: UInt32 = 0
    public var defaultSampleDuration: UInt32 = 0
}

/// Incremental fMP4 parser: feed bytes as they arrive, get AAC access units out.
public struct FMP4AudioDemuxer: Sendable {
    public private(set) var track: FMP4AudioTrack?
    private var buffer = Data()
    private var pendingSizes: [UInt32] = []
    private var pendingDataOffset: Int?
    private var moofStart = 0
    private var consumed = 0
    /// Hard cap on one box (a malformed size must not grow memory forever).
    static let maxBox = 8 * 1024 * 1024

    public init() {}

    /// Appends bytes and returns every complete AAC frame now available.
    public mutating func push(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 8 {
            let size32 = buffer.readUInt32(at: 0)
            let type = buffer.fourCC(at: 4)
            var size = Int(size32)
            var header = 8
            if size32 == 1 {
                guard buffer.count >= 16 else { break }
                size = Int(buffer.readUInt64(at: 8))
                header = 16
            }
            guard size >= header, size <= Self.maxBox else { throw FMP4Error.malformed }
            guard buffer.count >= size else { break }
            let box = buffer.subdata(in: header..<size)
            switch type {
            case "moov":
                track = try Self.parseMoov(box)
            case "moof":
                moofStart = consumed
                try parseMoof(box)
            case "mdat":
                frames.append(contentsOf: extract(mdat: box, mdatStart: consumed, header: header))
            default:
                break // ftyp, styp, sidx, free…
            }
            consumed += size
            buffer.removeSubrange(0..<size)
        }
        return frames
    }

    // MARK: moov

    static func parseMoov(_ moov: Data) throws -> FMP4AudioTrack {
        var trex: [UInt32: (UInt32, UInt32)] = [:]
        if let mvex = moov.child("mvex") {
            for t in mvex.children("trex") where t.count >= 24 {
                trex[t.readUInt32(at: 4)] = (t.readUInt32(at: 12), t.readUInt32(at: 16)) // duration, size
            }
        }
        for trak in moov.children("trak") {
            guard let mdia = trak.child("mdia"), let hdlr = mdia.child("hdlr"), hdlr.count >= 12,
                  hdlr.fourCC(at: 8) == "soun" else { continue }
            guard let tkhd = trak.child("tkhd"), let mdhd = mdia.child("mdhd") else { throw FMP4Error.malformed }
            let tkVersion = tkhd.first ?? 0
            let trackID = tkhd.readUInt32(at: tkVersion == 1 ? 20 : 12)
            let mdVersion = mdhd.first ?? 0
            let timescale = mdhd.readUInt32(at: mdVersion == 1 ? 20 : 12)
            guard let stsd = mdia.child("minf")?.child("stbl")?.child("stsd"), stsd.count >= 16 else { throw FMP4Error.malformed }
            // stsd: version/flags(4) count(4) then entries.
            let entry = stsd.subdata(in: 8..<stsd.count)
            let format = entry.fourCC(at: 4)
            guard format == "mp4a" else { throw FMP4Error.unsupportedCodec(format) }
            // AudioSampleEntry: 8 box hdr + 6 reserved + 2 dref + 8 reserved + 2 ch + 2 bits + 4 + 4 rate(16.16) = 36
            guard entry.count >= 36 else { throw FMP4Error.malformed }
            let channels = UInt32(entry.readUInt16(at: 24))
            let rate = Double(entry.readUInt32(at: 32) >> 16)
            let inner = entry.subdata(in: 36..<min(entry.count, Int(entry.readUInt32(at: 0))))
            guard let esds = inner.child("esds"), let asc = Self.audioSpecificConfig(esds: esds) else {
                throw FMP4Error.unsupportedCodec("mp4a-no-esds")
            }
            var track = FMP4AudioTrack(trackID: trackID, timescale: timescale, sampleRate: rate, channels: max(1, channels),
                                       audioSpecificConfig: asc)
            track.esds = esds.count > 4 ? esds.subdata(in: 4..<esds.count) : Data()
            // The sample entry's channel count is often a fixed 2; the AudioSpecificConfig is the truth.
            if let (ascRate, ascChannels) = Self.parseASC(asc) {
                track.sampleRate = ascRate
                track.channels = ascChannels
            }
            if let (duration, size) = trex[trackID] {
                track.defaultSampleDuration = duration
                track.defaultSampleSize = size
            }
            return track
        }
        throw FMP4Error.noAudioTrack
    }

    /// Sample rate and channel count from an AAC AudioSpecificConfig (ISO 14496-3 §1.6.2.1).
    static func parseASC(_ asc: Data) -> (Double, UInt32)? {
        guard asc.count >= 2 else { return nil }
        let b0 = UInt32(asc[asc.startIndex]), b1 = UInt32(asc[asc.startIndex + 1])
        let index = ((b0 & 0x07) << 1) | (b1 >> 7)
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard Int(index) < rates.count else { return nil }
        let channels = (b1 >> 3) & 0x0f
        guard (1...8).contains(channels) else { return nil }
        return (rates[Int(index)], channels)
    }

    /// Walks the ES_Descriptor → DecoderConfigDescriptor → DecoderSpecificInfo (tag 5).
    static func audioSpecificConfig(esds: Data) -> Data? {
        var i = 4 // version/flags
        func length() -> Int? {
            var value = 0
            for _ in 0..<4 {
                guard i < esds.count else { return nil }
                let b = esds[esds.startIndex + i]
                i += 1
                value = (value << 7) | Int(b & 0x7f)
                if b & 0x80 == 0 { return value }
            }
            return value
        }
        while i < esds.count {
            let tag = esds[esds.startIndex + i]
            i += 1
            guard let len = length() else { return nil }
            switch tag {
            case 0x03: // ES_ID(2) + flags(1) + optional fields
                guard i + 3 <= esds.count else { return nil }
                let flags = esds[esds.startIndex + i + 2]
                i += 3
                if flags & 0x80 != 0 { i += 2 }
                if flags & 0x40 != 0, i < esds.count { i += 1 + Int(esds[esds.startIndex + i]) }
                if flags & 0x20 != 0 { i += 2 }
            case 0x04: i += 13 // objectType, streamType, bufferSize(3), max/avg bitrate(8)
            case 0x05:
                guard i + len <= esds.count else { return nil }
                return esds.subdata(in: (esds.startIndex + i)..<(esds.startIndex + i + len))
            default: i += len
            }
        }
        return nil
    }

    // MARK: moof / mdat

    private mutating func parseMoof(_ moof: Data) throws {
        pendingSizes = []
        pendingDataOffset = nil
        guard let track else { return }
        for traf in moof.children("traf") {
            guard let tfhd = traf.child("tfhd"), tfhd.count >= 8, tfhd.readUInt32(at: 4) == track.trackID else { continue }
            let flags = tfhd.readUInt32(at: 0) & 0xffffff
            var o = 8
            if flags & 0x01 != 0 { o += 8 } // base data offset (go2rtc uses default-base-is-moof)
            if flags & 0x02 != 0 { o += 4 }
            if flags & 0x08 != 0 { o += 4 }
            var defaultSize = track.defaultSampleSize
            if flags & 0x10 != 0, tfhd.count >= o + 4 { defaultSize = tfhd.readUInt32(at: o) }
            for trun in traf.children("trun") {
                guard trun.count >= 8 else { throw FMP4Error.malformed }
                let tflags = trun.readUInt32(at: 0) & 0xffffff
                let count = Int(trun.readUInt32(at: 4))
                guard count < 100_000 else { throw FMP4Error.malformed }
                var p = 8
                if tflags & 0x01 != 0 { pendingDataOffset = Int(Int32(bitPattern: trun.readUInt32(at: p))); p += 4 }
                if tflags & 0x04 != 0 { p += 4 }
                for _ in 0..<count {
                    if tflags & 0x100 != 0 { p += 4 }
                    var size = defaultSize
                    if tflags & 0x200 != 0 { guard trun.count >= p + 4 else { throw FMP4Error.malformed }; size = trun.readUInt32(at: p); p += 4 }
                    if tflags & 0x400 != 0 { p += 4 }
                    if tflags & 0x800 != 0 { p += 4 }
                    pendingSizes.append(size)
                }
            }
        }
    }

    private mutating func extract(mdat: Data, mdatStart: Int, header: Int) -> [Data] {
        guard !pendingSizes.isEmpty else { return [] }
        // data_offset is relative to the moof start (default-base-is-moof).
        var offset: Int
        if let dataOffset = pendingDataOffset {
            offset = (moofStart + dataOffset) - (mdatStart + header)
        } else {
            offset = 0
        }
        var frames: [Data] = []
        for size in pendingSizes {
            let s = Int(size)
            guard offset >= 0, s > 0, offset + s <= mdat.count else { break }
            frames.append(mdat.subdata(in: (mdat.startIndex + offset)..<(mdat.startIndex + offset + s)))
            offset += s
        }
        pendingSizes = []
        pendingDataOffset = nil
        return frames
    }
}

/// AAC access units → 16 kHz mono Float32 (AVAudioConverter, Apple's decoder).
public final class AACDecoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let lock = NSLock()

    public init(track: FMP4AudioTrack) throws {
        guard let input = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: track.sampleRate,
                                                   AVNumberOfChannelsKey: track.channels]),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMAudio.sampleRate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw FMP4Error.decoderFailed }
        // AudioToolbox takes the raw AudioSpecificConfig as the AAC cookie.
        converter.magicCookie = track.audioSpecificConfig
        self.input = input
        self.output = output
        self.converter = converter
    }

    /// Decodes a batch of access units (in order).
    public func decode(_ frames: [Data]) throws -> [Float] {
        guard !frames.isEmpty else { return [] }
        return try lock.withLock {
            let maxSize = frames.map(\.count).max() ?? 0
            var queue = frames[...]
            let packetBuffer = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: max(1, maxSize))
            let ratio = PCMAudio.sampleRate / input.sampleRate
            let capacity = AVAudioFrameCount(Double(frames.count * 1024) * ratio + 2048)
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw FMP4Error.decoderFailed }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                guard let frame = queue.popFirst() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                frame.withUnsafeBytes { raw in
                    packetBuffer.data.copyMemory(from: raw.baseAddress!, byteCount: frame.count)
                }
                packetBuffer.byteLength = UInt32(frame.count)
                packetBuffer.packetCount = 1
                packetBuffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
                inputStatus.pointee = .haveData
                return packetBuffer
            }
            guard status != .error, let channel = out.floatChannelData else {
                throw FMP4Error.decoderFailedStatus(error?.code ?? -1)
            }
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        }
    }
}

/// A camera's live audio from go2rtc's fMP4 stream. `open` returns the HTTP
/// body as raw bytes (the Hub passes its authenticated Frigate session).
public struct Go2rtcAudioSource: AssistantAudioSource {
    public let camera: String
    private let open: @Sendable () async throws -> AsyncThrowingStream<Data, Error>

    public init(camera: String, open: @escaping @Sendable () async throws -> AsyncThrowingStream<Data, Error>) {
        self.camera = camera
        self.open = open
    }

    public func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        let open = open
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var demuxer = FMP4AudioDemuxer()
                    var decoder: AACDecoder?
                    for try await bytes in try await open() {
                        try Task.checkCancellation()
                        let frames = try demuxer.push(bytes)
                        if decoder == nil, let track = demuxer.track { decoder = try AACDecoder(track: track) }
                        guard let decoder, !frames.isEmpty else { continue }
                        let samples = try decoder.decode(frames)
                        if !samples.isEmpty { continuation.yield(AudioChunk(samples: samples)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Box helpers

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) << 32 | UInt64(readUInt32(at: offset + 4))
    }

    func fourCC(at offset: Int) -> String {
        guard offset + 4 <= count else { return "" }
        return String(bytes: self[(startIndex + offset)..<(startIndex + offset + 4)], encoding: .ascii) ?? ""
    }

    /// Child boxes of a container box body.
    func children(_ type: String) -> [Data] {
        var out: [Data] = []
        var i = 0
        while i + 8 <= count {
            let size = Int(readUInt32(at: i))
            guard size >= 8, i + size <= count else { break }
            if fourCC(at: i + 4) == type { out.append(subdata(in: (startIndex + i + 8)..<(startIndex + i + size))) }
            i += size
        }
        return out
    }

    func child(_ type: String) -> Data? { children(type).first }
}
