// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClearDisk",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/DiskScanBackend")
    ],
    targets: [
        .target(
            name: "DiskScannerCore",
            dependencies: [
                .product(name: "DiskScanBackend", package: "DiskScanBackend")
            ],
            path: "Sources/DiskScannerCore"
        ),
        .executableTarget(
            name: "ClearDisk",
            dependencies: ["DiskScannerCore"],
            path: "Sources/ClearDisk"
        ),
        .testTarget(
            name: "ClearDiskTests",
            dependencies: ["ClearDisk", "DiskScannerCore"],
            path: "Tests/ClearDiskTests"
        )
    ]
)
