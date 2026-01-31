// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacVisionServer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
    ],
    targets: [
        // Pure domain logic (no external dependencies except Foundation + Vision)
        .target(
            name: "VisionCore",
            dependencies: [],
            path: "Sources/VisionCore"
        ),
        // Executable that runs the Vapor server
        .executableTarget(
            name: "App",
            dependencies: [
                "VisionCore",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/App",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "VisionCoreTests",
            dependencies: ["VisionCore"],
            path: "Tests/VisionCoreTests"
        ),
    ]
)
