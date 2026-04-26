// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BugReportKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "BugReportKit",
            targets: ["BugReportKit"]
        ),
    ],
    targets: [
        .target(
            name: "BugReportKit"
        ),
        .testTarget(
            name: "BugReportKitTests",
            dependencies: ["BugReportKit"]
        ),
    ]
)
