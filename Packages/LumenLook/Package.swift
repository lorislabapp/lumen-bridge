// swift-tools-version: 6.2
import PackageDescription

// LumenLook — Lumen Hub "Look" step: after the assistant acts (light on, TV on,
// shutters closed), check the device's real state on a camera.
// Per-device area drawn by the owner → cheap pixel test (Accelerate/vImage) →
// Frigate state classifier when one exists → small vision model (llama-server,
// JSON schema) only when unsure. Three outcomes: confirmed / contradicted /
// unknown (with a reason). No third-party dependency; Apple frameworks only.
// The Hub adapts it to LumenAssistant's `ActionVerifier` (LumenBridge/Hub/Look).
let package = Package(
    name: "LumenLook",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumenLook", targets: ["LumenLook"]),
    ],
    targets: [
        .target(name: "LumenLook"),
        .testTarget(name: "LumenLookTests", dependencies: ["LumenLook"]),
    ]
)
