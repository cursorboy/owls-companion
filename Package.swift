// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OwlsCompanion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OwlsCompanion", targets: ["OwlsCompanionApp"])
    ],
    targets: [
        .target(
            name: "OwlsCompanionCore",
            path: "Sources/OwlsCompanionCore",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "OwlsCompanionApp",
            dependencies: ["OwlsCompanionCore"],
            path: "Sources/OwlsCompanionApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "OwlsCompanionCoreTests",
            dependencies: ["OwlsCompanionCore"],
            path: "Tests/OwlsCompanionCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
