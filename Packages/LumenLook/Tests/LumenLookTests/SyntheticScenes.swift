import CoreGraphics
import Foundation
@testable import LumenLook

/// Core Graphics living room, 640×360: wall, floor, sofa, frames, a lamp,
/// a TV, a window with roller shutters and a door. Every device can be set,
/// with sensor noise, IR night mode, exposure change and camera shift.
struct Scene {
    var lampOn = false
    var tvOn = false
    /// TV picture seed: change it between frames for a moving picture.
    var tvFrame = 0
    /// Off TV reflecting the room (glare).
    var tvReflection = false
    var shutterClosed = false
    var doorOpen = false
    /// Active-IR night: grey, low contrast, dark outside.
    var night = false
    /// 1 = normal; 0.8 = cloud passing.
    var exposure = 1.0
    /// Camera shift as a share of the frame.
    var shiftX = 0.0
    var shiftY = 0.0
    /// All black (lens covered / no IR).
    var black = false
    var noiseSeed: UInt64 = 1
    var noise = 4.0

    static let width = 640
    static let height = 360

    // Areas as the owner would draw them (top-left normalised).
    static let lamp = LookRect(x: 0.06, y: 0.22, width: 0.12, height: 0.30)
    static let tv = LookRect(x: 0.40, y: 0.28, width: 0.26, height: 0.26)
    static let window = LookRect(x: 0.76, y: 0.12, width: 0.18, height: 0.42)
    static let door = LookRect(x: 0.22, y: 0.25, width: 0.11, height: 0.58)

    func image() -> CGImage {
        let w = Self.width, h = Self.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Core Graphics is bottom-left; draw in top-left coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(shiftX * Double(w)), y: CGFloat(shiftY * Double(h)))
        if black {
            fill(ctx, CGRect(x: -w, y: -h, width: 3 * w, height: 3 * h), 0.02, 0.02, 0.02)
            return finish(ctx)
        }
        func r(_ rect: LookRect) -> CGRect {
            CGRect(x: rect.x * Double(w), y: rect.y * Double(h), width: rect.width * Double(w), height: rect.height * Double(h))
        }
        // Wall and floor (oversized so a shift does not show empty borders).
        fill(ctx, CGRect(x: -w, y: -h, width: 3 * w, height: Int(Double(h) * 1.7)), 0.78, 0.70, 0.58)
        fill(ctx, CGRect(x: -w, y: Int(Double(h) * 0.72), width: 3 * w, height: h), 0.45, 0.32, 0.22)
        // Floor boards.
        for i in stride(from: -w, to: 2 * w, by: 37) {
            fill(ctx, CGRect(x: i, y: Int(Double(h) * 0.72), width: 2, height: h), 0.36, 0.25, 0.17)
        }
        // Skirting, picture frames, shelf, plant: texture for registration.
        fill(ctx, CGRect(x: -w, y: Int(Double(h) * 0.71), width: 3 * w, height: 5), 0.95, 0.95, 0.92)
        fill(ctx, CGRect(x: 250, y: 30, width: 60, height: 45), 0.20, 0.25, 0.45)
        fill(ctx, CGRect(x: 256, y: 36, width: 48, height: 33), 0.85, 0.55, 0.30)
        fill(ctx, CGRect(x: 330, y: 40, width: 30, height: 40), 0.15, 0.40, 0.30)
        fill(ctx, CGRect(x: 160, y: 50, width: 70, height: 6), 0.40, 0.28, 0.18)
        fill(ctx, CGRect(x: 165, y: 30, width: 12, height: 20), 0.70, 0.20, 0.20)
        fill(ctx, CGRect(x: 185, y: 35, width: 10, height: 15), 0.20, 0.50, 0.70)
        fill(ctx, CGRect(x: 600, y: 200, width: 24, height: 60), 0.25, 0.50, 0.20)
        // Sofa and table.
        fill(ctx, CGRect(x: 250, y: 215, width: 230, height: 55), 0.30, 0.38, 0.52)
        fill(ctx, CGRect(x: 250, y: 200, width: 230, height: 22), 0.26, 0.33, 0.46)
        fill(ctx, CGRect(x: 300, y: 285, width: 120, height: 10), 0.55, 0.40, 0.25)

        // Lamp: shade + glow on the wall.
        let lamp = r(Self.lamp)
        fill(ctx, CGRect(x: lamp.midX - 3, y: lamp.midY, width: 6, height: lamp.height * 0.55), 0.25, 0.22, 0.20)
        if lampOn {
            let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 0.85),
                                           CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0)] as CFArray,
                                  locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: lamp.midX, y: lamp.minY + lamp.height * 0.3), startRadius: 0,
                                   endCenter: CGPoint(x: lamp.midX, y: lamp.minY + lamp.height * 0.3), endRadius: lamp.width * 0.9,
                                   options: [])
            fill(ctx, CGRect(x: lamp.minX + lamp.width * 0.15, y: lamp.minY + lamp.height * 0.1,
                             width: lamp.width * 0.7, height: lamp.height * 0.35), 1.0, 0.97, 0.85)
        } else {
            fill(ctx, CGRect(x: lamp.minX + lamp.width * 0.15, y: lamp.minY + lamp.height * 0.1,
                             width: lamp.width * 0.7, height: lamp.height * 0.35), 0.62, 0.56, 0.45)
        }

        // TV: bezel + screen.
        let tv = r(Self.tv)
        fill(ctx, tv.insetBy(dx: -4, dy: -4), 0.08, 0.08, 0.08)
        if tvOn {
            var rng = SplitMix(seed: UInt64(1000 + tvFrame))
            fill(ctx, tv, 0.25, 0.35, 0.55)
            for _ in 0..<14 {
                let bw = Double(rng.next() % 60 + 15), bh = Double(rng.next() % 40 + 10)
                let bx = tv.minX + Double(rng.next() % UInt64(max(1, Int(tv.width - bw))))
                let by = tv.minY + Double(rng.next() % UInt64(max(1, Int(tv.height - bh))))
                fill(ctx, CGRect(x: bx, y: by, width: bw, height: bh),
                     Double(rng.next() % 100) / 100, Double(rng.next() % 100) / 100, Double(rng.next() % 100) / 100)
            }
        } else {
            fill(ctx, tv, 0.06, 0.06, 0.07)
            if tvReflection {
                // The window's reflection as a soft bright patch.
                let glare = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       colors: [CGColor(srgbRed: 0.75, green: 0.75, blue: 0.8, alpha: 0.55),
                                                CGColor(srgbRed: 0.5, green: 0.5, blue: 0.55, alpha: 0)] as CFArray,
                                       locations: [0, 1])!
                ctx.drawLinearGradient(glare, start: CGPoint(x: tv.maxX, y: tv.minY), end: CGPoint(x: tv.midX, y: tv.midY), options: [])
            }
        }

        // Window: outside view or slats.
        let win = r(Self.window)
        fill(ctx, win.insetBy(dx: -5, dy: -5), 0.95, 0.95, 0.95)
        if shutterClosed {
            let slat = 8.0
            var y = win.minY
            var i = 0
            while y < win.maxY {
                let shade = i % 2 == 0 ? 0.82 : 0.58
                fill(ctx, CGRect(x: win.minX, y: y, width: win.width, height: min(slat / 2 + (i % 2 == 0 ? 1 : -1), win.maxY - y)),
                     shade, shade * 0.97, shade * 0.9)
                y += slat / 2 + (i % 2 == 0 ? 1 : -1)
                i += 1
            }
        } else {
            let night = self.night
            fill(ctx, CGRect(x: win.minX, y: win.minY, width: win.width, height: win.height * 0.6),
                 night ? 0.05 : 0.55, night ? 0.06 : 0.75, night ? 0.1 : 0.95)
            fill(ctx, CGRect(x: win.minX, y: win.minY + win.height * 0.6, width: win.width, height: win.height * 0.4),
                 night ? 0.04 : 0.25, night ? 0.05 : 0.55, night ? 0.04 : 0.20)
            fill(ctx, CGRect(x: win.minX + win.width * 0.2, y: win.minY + win.height * 0.35, width: win.width * 0.3,
                             height: win.height * 0.35), night ? 0.03 : 0.15, night ? 0.04 : 0.42, night ? 0.03 : 0.12)
            fill(ctx, CGRect(x: win.midX - 2, y: win.minY, width: 4, height: win.height), 0.95, 0.95, 0.95)
        }

        // Door: flush panel or swung open onto a dark hallway.
        let door = r(Self.door)
        fill(ctx, door.insetBy(dx: -4, dy: -4), 0.92, 0.90, 0.86)
        if doorOpen {
            fill(ctx, door, 0.16, 0.13, 0.11)
            fill(ctx, CGRect(x: door.minX, y: door.minY, width: door.width * 0.22, height: door.height), 0.55, 0.38, 0.24)
        } else {
            fill(ctx, door, 0.58, 0.40, 0.25)
            fill(ctx, CGRect(x: door.minX + door.width * 0.12, y: door.minY + door.height * 0.08,
                             width: door.width * 0.76, height: door.height * 0.36), 0.53, 0.36, 0.22)
            fill(ctx, CGRect(x: door.maxX - 10, y: door.midY, width: 5, height: 5), 0.85, 0.75, 0.3)
        }
        return finish(ctx)
    }

    private func fill(_ ctx: CGContext, _ rect: CGRect, _ r: Double, _ g: Double, _ b: Double) {
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(rect)
    }

    private func fill(_ ctx: CGContext, _ rect: CGRect, _ v: Double) { fill(ctx, rect, v, v, v) }

    /// Exposure, IR night conversion and sensor noise on the raw pixels.
    private func finish(_ ctx: CGContext) -> CGImage {
        let w = Self.width, h = Self.height
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var rng = SplitMix(seed: noiseSeed)
        for i in 0..<(w * h) {
            var r = Double(p[i * 4]), g = Double(p[i * 4 + 1]), b = Double(p[i * 4 + 2])
            if night {
                // IR: grey, compressed; lit lamp and lit screen stay bright.
                let y = 0.299 * r + 0.587 * g + 0.114 * b
                let v = 18 + y * 0.42 + (y > 225 ? 70 : 0)
                r = v; g = v; b = v
            }
            let n = noise > 0 ? rng.gaussian() * noise : 0
            r = r * exposure + n; g = g * exposure + n; b = b * exposure + n
            p[i * 4] = UInt8(max(0, min(255, r)))
            p[i * 4 + 1] = UInt8(max(0, min(255, g)))
            p[i * 4 + 2] = UInt8(max(0, min(255, b)))
        }
        return ctx.makeImage()!
    }
}

/// Deterministic generator (SplitMix64) for noise and TV pictures.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
