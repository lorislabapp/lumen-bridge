import CoreGraphics
import Foundation
// Prints "<windowID> <width>x<height>" for on-screen windows owned by "Lumen Bridge".
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Lumen Bridge" {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, "\(b["Width"] ?? 0)x\(b["Height"] ?? 0)")
}
