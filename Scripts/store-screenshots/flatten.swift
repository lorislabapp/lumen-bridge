import CoreGraphics
import Foundation
import ImageIO

// flatten <in.png> <out.png>: draws the image on an opaque dark background
// and writes an RGB PNG without alpha (App Store Connect rejects alpha).
let args = CommandLine.arguments
guard args.count == 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
      let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
ctx.fill(rect)
ctx.draw(image, in: rect)
guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, out, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
