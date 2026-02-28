// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClearDisk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClearDisk",
            path: "Sources/ClearDisk"
        )
    ]
)
