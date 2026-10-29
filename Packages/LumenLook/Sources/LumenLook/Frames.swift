import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One decoded camera frame and when it was taken.
public struct CameraFrame: @unchecked Sendable {
    // CGImage is immutable and thread-safe; Apple has not marked it Sendable.
    public let image: CGImage
    /// Frigate's `X-Frame-Time` (capture time). Nil when the server did not send it.
    public let frameTime: Date?
    /// When the Hub received it.
    public let fetchedAt: Date

    public init(image: CGImage, frameTime: Date?, fetchedAt: Date = Date()) {
        self.image = image
        self.frameTime = frameTime
        self.fetchedAt = fetchedAt
    }

    /// Best known capture time. Without `X-Frame-Time` the fetch time is an
    /// upper bound only, which is still enough to prove "after the command".
    public var takenAt: Date { frameTime ?? fetchedAt }
}

public enum LookFrameError: Error, Equatable, Sendable {
    /// Camera disabled in Frigate (privacy).
    case cameraDisabled
    case cameraOffline
    case unauthorized
    case badImage
}

/// Frigate `/api/<camera>/latest.jpg` behind a seam (tests use synthetic frames).
public protocol LookFrameSource: Sendable {
    /// Latest frame, at most `height` pixels tall.
    func frame(camera: String, height: Int) async throws -> CameraFrame
}

public enum JPEG {
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func encode(_ image: CGImage, quality: Double = 0.75) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Frigate sends `X-Frame-Time` as Unix seconds with a fraction.
    public static func frameTime(header: String?) -> Date? {
        guard let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)), seconds > 1_000_000_000 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

extension CGImage {
    /// Crop in normalised coordinates (top-left origin).
    func crop(_ area: LookRect) -> CGImage? {
        cropping(to: area.pixels(width: width, height: height))
    }

    /// Down-scaled copy, longest side ≤ `maxSide`.
    func scaled(maxSide: Int) -> CGImage? {
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        if scale >= 1 { return self }
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
