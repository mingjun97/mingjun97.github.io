// swift-tools-version:5.9
import PackageDescription

// Platform-neutral logic for Cashline: models, the due-date / cash-flow
// engine, persistence and the bank-sync layer. Pure Foundation, so it builds
// and tests on Linux as well as iOS.
let package = Package(
    name: "CashlineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CashlineCore", targets: ["CashlineCore"]),
    ],
    targets: [
        .target(name: "CashlineCore"),
        .testTarget(
            name: "CashlineCoreTests",
            dependencies: ["CashlineCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
