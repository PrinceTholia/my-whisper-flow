// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "WhisperApp",
            dependencies: [],
            path: "Sources"
        )
    ]
)
