import CoreGraphics
import Foundation
import Vision

/// Has the camera moved since the owner drew the area?
public struct PoseReading: Sendable, Equatable {
    /// Translation between reference and now, as a share of the frame (0…).
    public var shift: Double
    /// Offset to apply to the area (normalised), valid when `moved` is false.
    public var dx: Double
    public var dy: Double
    /// Vision feature-print distance (nil when skipped, e.g. day reference vs night IR).
    public var featureDistance: Double?
    public var moved: Bool
}

public protocol CameraPoseChecking: Sendable {
    /// `lightingDiffers`: reference in colour, now in IR (or the reverse).
    func check(reference: CGImage, current: CGImage, lightingDiffers: Bool) async -> PoseReading?
}

/// Vision: translational registration (how far the view slid) plus a
/// feature-print distance (has the view changed altogether: turned, replaced).
public struct VisionPoseCheck: CameraPoseChecking {
    /// Above this share of the frame the area is no longer trusted.
    public var movedShift: Double
    /// Below this the area is used as drawn.
    public var driftShift: Double
    /// Feature-print distance above which the view is a different view.
    public var movedDistance: Double

    public init(movedShift: Double = 0.05, driftShift: Double = 0.01, movedDistance: Double = 0.85) {
        self.movedShift = movedShift
        self.driftShift = driftShift
        self.movedDistance = movedDistance
    }

    public func check(reference: CGImage, current: CGImage, lightingDiffers: Bool) async -> PoseReading? {
        guard let ref = reference.scaled(maxSide: 512), let now = current.scaled(maxSide: 512) else { return nil }
        var shift = 0.0, dx = 0.0, dy = 0.0
        var registered = false
        // Classic VN API: the Swift `Vision` structs only offer the stateful tracking variant.
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: ref, options: [:])
        let handler = VNImageRequestHandler(cgImage: now, options: [:])
        if (try? handler.perform([request])) != nil,
           let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
            let t = observation.alignmentTransform
            dx = Double(t.tx) / Double(now.width)
            dy = Double(t.ty) / Double(now.height)
            shift = (dx * dx + dy * dy).squareRoot()
            registered = true
        }
        var distance: Double?
        if !lightingDiffers {
            do {
                let request = GenerateImageFeaturePrintRequest()
                let a = try await request.perform(on: ref)
                let b = try await request.perform(on: now)
                distance = try a.distance(to: b)
            } catch {
                distance = nil
            }
        }
        guard registered || distance != nil else { return nil }
        let moved = shift > movedShift || (distance ?? 0) > movedDistance
        // Vision's transform is in a bottom-left frame: flip y for the UI's top-left area.
        let apply = shift > driftShift && !moved
        return PoseReading(shift: shift, dx: apply ? dx : 0, dy: apply ? -dy : 0, featureDistance: distance, moved: moved)
    }
}

/// People (or other things) standing in front of the area.
public protocol OcclusionChecking: Sendable {
    /// Boxes in normalised top-left coordinates.
    func occluders(in image: CGImage) async -> [LookRect]
}

public struct NoOcclusionCheck: OcclusionChecking {
    public init() {}
    public func occluders(in image: CGImage) async -> [LookRect] { [] }
}

/// Vision human rectangles (full body), on device.
public struct VisionHumanOcclusion: OcclusionChecking {
    public init() {}
    public func occluders(in image: CGImage) async -> [LookRect] {
        var request = DetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        guard let small = image.scaled(maxSide: 640),
              let people = try? await request.perform(on: small) else { return [] }
        return people.filter { $0.confidence > 0.5 }.map { person in
            let box = person.boundingBox.cgRect
            return LookRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }
}

/// Night, dark, privacy, occlusion: when the camera cannot be trusted at all.
public enum SceneJudge {
    /// Share of the area that must be covered to call it hidden.
    public static let occludedShare = 0.3

    public static func occluded(_ area: LookRect, by boxes: [LookRect]) -> Bool {
        let covered = boxes.reduce(0) { $0 + area.intersection($1) }
        return covered / max(area.area, 1e-6) >= occludedShare
    }
}
