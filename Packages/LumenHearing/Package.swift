// swift-tools-version: 6.2
import PackageDescription

// LumenHearing — on-device transcription of Frigate `speech` events for Lumen Hub.
// Core (`LumenHearing`) has no third-party dependency; the Parakeet engine and
// Silero VAD live in `LumenHearingFluid` (FluidAudio, Apache-2.0).
// See THIRD_PARTY_NOTICES.md for model licences (CC-BY-4.0 attribution).
let package = Package(
    name: "LumenHearing",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumenHearing", targets: ["LumenHearing", "LumenHearingFluid"]),
    ],
    dependencies: [
        // Pinned exactly (released 2026-10-07). The NeMo text-normalisation
        // trait is turned off: ASR + VAD need no prebuilt Rust binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "LumenHearing"),
        .target(name: "LumenHearingFluid", dependencies: [
            "LumenHearing",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(
            name: "LumenHearingTests",
            dependencies: ["LumenHearing", "LumenHearingFluid"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
