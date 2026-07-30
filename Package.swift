// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperSRT",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WhisperSRT",
            path: "Sources/WhisperSRT"
        )
    ]
)
