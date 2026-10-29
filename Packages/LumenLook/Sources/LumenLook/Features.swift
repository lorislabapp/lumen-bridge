import Accelerate
import CoreGraphics
import Foundation

/// Numbers that describe one area of one frame. Cheap: ~1 ms on a 128 px crop.
public struct ROIFeatures: Codable, Sendable, Equatable {
    /// Rec. 601 luma, 0…255.
    public var meanLuma: Double
    public var stdLuma: Double
    /// Mean HSV saturation 0…1 (≈ 0 in infrared night mode).
    public var meanSaturation: Double
    /// Mean |∂/∂x| (vertical edges) and |∂/∂y| (horizontal edges), luma units.
    public var edgeX: Double
    public var edgeY: Double
    /// 0…1: how periodic the row profile is (horizontal slats).
    public var stripeScore: Double
    /// Share of pixels with luma > 200.
    public var brightFraction: Double
    /// 32×32 luma thumbnail, row-major (temporal change, sample matching).
    public var thumb: [UInt8]

    public static let thumbSide = 32

    /// Horizontal-edge share (slats → close to 1).
    public var horizontalEdgeRatio: Double { edgeY / max(edgeX + edgeY, 1e-6) }

    /// Mean absolute thumbnail difference, 0…255.
    public func change(to other: ROIFeatures) -> Double {
        ROIFeatures.mad(thumb, other.thumb)
    }

    static func mad(_ a: [UInt8], _ b: [UInt8], mask: [Bool]? = nil) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0, n = 0.0
        for i in 0..<a.count where mask?[i] ?? true {
            sum += abs(Double(a[i]) - Double(b[i]))
            n += 1
        }
        return n > 0 ? sum / n : 0
    }
}

/// Whole-frame numbers for scene checks (night, dark, global change).
public struct SceneFeatures: Sendable, Equatable {
    public var meanLuma: Double
    public var meanSaturation: Double
    public var thumb: [UInt8]

    /// Active-IR night mode: the picture is grey. Colour cameras by day stay
    /// well above 0.06 mean saturation even in dull rooms.
    public var isInfrared: Bool { meanSaturation < 0.045 }
    /// Too dark to judge anything (no IR or IR off).
    public var isTooDark: Bool { meanLuma < 14 }

    /// Change outside `area` between two frames (exposure shifts, people, camera moved).
    public func changeOutside(_ area: LookRect, to other: SceneFeatures) -> Double {
        let side = ROIFeatures.thumbSide
        var mask = [Bool](repeating: true, count: side * side)
        let grown = area.expanded(by: 0.1)
        for row in 0..<side {
            for col in 0..<side {
                let cell = LookRect(x: Double(col) / Double(side), y: Double(row) / Double(side),
                                    width: 1 / Double(side), height: 1 / Double(side))
                if grown.intersection(cell) > 0 { mask[row * side + col] = false }
            }
        }
        if !mask.contains(true) { return 0 }
        return ROIFeatures.mad(thumb, other.thumb, mask: mask)
    }
}

/// Accelerate (vImage + vDSP) feature extraction.
public enum FeatureExtractor {
    /// Max side of the analysed crop. Bigger buys nothing for these tests.
    static let analysisSide = 128

    public static func features(of image: CGImage, area: LookRect) -> ROIFeatures? {
        let rect = area.pixels(width: image.width, height: image.height)
        guard let crop = image.cropping(to: rect) else { return nil }
        return features(of: crop)
    }

    public static func features(of image: CGImage) -> ROIFeatures? {
        guard let raster = Raster(image: image, maxSide: analysisSide) else { return nil }
        let luma = raster.luma()
        let floats = raster.lumaFloat(luma)
        let n = vDSP_Length(floats.count)
        var mean: Float = 0, std: Float = 0
        floats.withUnsafeBufferPointer { p in vDSP_normalize(p.baseAddress!, 1, nil, 1, &mean, &std, n) }
        let (gx, gy) = raster.sobel(floats)
        var bright: Float = 0
        var thresholded = [Float](repeating: 0, count: floats.count)
        let threshold: Float = 200
        var one: Float = 1, zero: Float = 0
        // 1 where luma > 200, else 0, then mean.
        floats.withUnsafeBufferPointer { src in
            thresholded.withUnsafeMutableBufferPointer { dst in
                var t = threshold
                vDSP_vthrsc(src.baseAddress!, 1, &t, &one, dst.baseAddress!, 1, n)
                vDSP_vthres(dst.baseAddress!, 1, &zero, dst.baseAddress!, 1, n)
            }
        }
        // vthrsc gives ±1; vthres keeps the +1s.
        vDSP_meanv(thresholded, 1, &bright, n)
        return ROIFeatures(meanLuma: Double(mean), stdLuma: Double(std), meanSaturation: raster.meanSaturation(),
                           edgeX: gx, edgeY: gy, stripeScore: raster.stripeScore(floats),
                           brightFraction: Double(bright), thumb: Raster(image: image, exactSide: ROIFeatures.thumbSide)?.luma() ?? [])
    }

    public static func scene(of image: CGImage) -> SceneFeatures? {
        guard let small = Raster(image: image, maxSide: 160),
              let thumb = Raster(image: image, exactSide: ROIFeatures.thumbSide) else { return nil }
        let luma = small.lumaFloat(small.luma())
        var mean: Float = 0
        vDSP_meanv(luma, 1, &mean, vDSP_Length(luma.count))
        return SceneFeatures(meanLuma: Double(mean), meanSaturation: small.meanSaturation(), thumb: thumb.luma())
    }
}

/// RGBA8 copy of an image, drawn at a small fixed size.
struct Raster {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    init?(image: CGImage, maxSide: Int) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        self.init(image: image, width: max(3, Int((Double(image.width) * scale).rounded())),
                  height: max(3, Int((Double(image.height) * scale).rounded())))
    }

    init?(image: CGImage, exactSide: Int) {
        self.init(image: image, width: exactSide, height: exactSide)
    }

    init?(image: CGImage, width: Int, height: Int) {
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        rgba = bytes
    }

    /// Rec. 601 luma through vImage's matrix multiply (RGBX → Planar8).
    func luma() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var src = rgba
        src.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var srcBuf = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                var dstBuf = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width)
                // Order R, G, B, X; divisor 1000.
                let matrix: [Int16] = [299, 587, 114, 0]
                let pre: [Int16] = [0, 0, 0, 0]
                _ = vImageMatrixMultiply_ARGB8888ToPlanar8(&srcBuf, &dstBuf, matrix, 1000, pre, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    func lumaFloat(_ luma: [UInt8]) -> [Float] {
        var out = [Float](repeating: 0, count: luma.count)
        vDSP_vfltu8(luma, 1, &out, 1, vDSP_Length(luma.count))
        return out
    }

    func meanSaturation() -> Double {
        var total = 0.0
        let count = width * height
        for i in 0..<count {
            let r = Double(rgba[i * 4]), g = Double(rgba[i * 4 + 1]), b = Double(rgba[i * 4 + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            // Ignore near-black pixels: their hue is noise.
            if mx > 12 { total += (mx - mn) / mx }
        }
        return total / Double(max(count, 1))
    }

    /// Mean |Sobel x| and |Sobel y| via vImage float convolution.
    func sobel(_ luma: [Float]) -> (Double, Double) {
        let kx: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1].map { $0 / 4 }
        let ky: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1].map { $0 / 4 }
        func convolve(_ kernel: [Float]) -> Double {
            var src = luma
            var dst = [Float](repeating: 0, count: luma.count)
            src.withUnsafeMutableBytes { s in
                dst.withUnsafeMutableBytes { d in
                    var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                    var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                    _ = vImageConvolve_PlanarF(&sb, &db, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
            var m: Float = 0
            vDSP_meamgv(dst, 1, &m, vDSP_Length(dst.count))
            return Double(m)
        }
        return (convolve(kx), convolve(ky))
    }

    /// Periodicity of the row profile: autocorrelation peak of the first
    /// difference of row means (removes slow light gradients), lag 2…rows/3.
    /// Slats give a strong peak (≥ 0.5); natural scenes stay below ~0.3.
    func stripeScore(_ luma: [Float]) -> Double {
        guard height >= 12 else { return 0 }
        var rows = [Float](repeating: 0, count: height)
        luma.withUnsafeBufferPointer { p in
            for r in 0..<height {
                var m: Float = 0
                vDSP_meanv(p.baseAddress! + r * width, 1, &m, vDSP_Length(width))
                rows[r] = m
            }
        }
        var diff = [Float](repeating: 0, count: height - 1)
        for i in 0..<(height - 1) { diff[i] = rows[i + 1] - rows[i] }
        var mean: Float = 0
        vDSP_meanv(diff, 1, &mean, vDSP_Length(diff.count))
        var neg = -mean
        vDSP_vsadd(diff, 1, &neg, &diff, 1, vDSP_Length(diff.count))
        var energy: Float = 0
        vDSP_dotpr(diff, 1, diff, 1, &energy, vDSP_Length(diff.count))
        // Flat profile (uniform panel, darkness): no stripes. 0.5 luma rms floor.
        guard energy / Float(diff.count) > 0.25 else { return 0 }
        func r(_ lag: Int) -> Float {
            guard lag < diff.count else { return 0 }
            var dot: Float = 0
            vDSP_dotpr(diff, 1, Array(diff[lag...]), 1, &dot, vDSP_Length(diff.count - lag))
            // Normalise by overlap so long lags are not penalised.
            return dot / energy * Float(diff.count) / Float(diff.count - lag)
        }
        // A real slat pattern repeats: high at the period AND at twice the period
        // (at least four periods in the area). Two or three edges (a horizon, a
        // window bar) give one lucky lag only.
        var best: Float = 0
        let maxLag = max(2, diff.count / 4)
        for lag in 2...maxLag {
            best = max(best, min(r(lag), r(2 * lag)))
        }
        return Double(min(max(best, 0), 1))
    }
}
