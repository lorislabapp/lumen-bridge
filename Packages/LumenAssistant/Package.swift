// swift-tools-version: 6.2
import PackageDescription

// LumenAssistant — Lumen Hub hands-free voice assistant: listen → understand → act.
// Indoor camera audio → streaming VAD endpointing → utterance ASR (LumenHearing
// engines) → wake phrase / natural-mode gate → FR+EN rule parser (local LLM
// fallback via llama-server) → deterministic safety policy → Home Assistant.
// Core (`LumenAssistant`) has no third-party dependency beyond LumenHearing;
// Silero streaming VAD lives in `LumenAssistantFluid` (FluidAudio, Apache-2.0).
// Tool model uses LorisAI's effect vocabulary (readOnly / write / destructive,
// proposal + single-use receipt) so it can migrate once LorisAI qualifies.
let package = Package(
    name: "LumenAssistant",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumenAssistant", targets: ["LumenAssistant", "LumenAssistantFluid"]),
    ],
    dependencies: [
        .package(path: "../LumenHearing"),
        // Same exact pin as LumenHearing (one FluidAudio in the Hub).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "LumenAssistant", dependencies: [
            .product(name: "LumenHearing", package: "LumenHearing"),
        ]),
        .target(name: "LumenAssistantFluid", dependencies: [
            "LumenAssistant",
            .product(name: "LumenHearing", package: "LumenHearing"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(
            name: "LumenAssistantTests",
            dependencies: ["LumenAssistant", "LumenAssistantFluid",
                           .product(name: "LumenHearing", package: "LumenHearing")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
