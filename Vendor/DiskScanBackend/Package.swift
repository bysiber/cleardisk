// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DiskScanBackend",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "DiskScanBackend", targets: ["DiskScanBackend"])
    ],
    targets: [
        .target(
            name: "DiskScanBackend",
            path: "BackendSources",
            sources: [
                "ClearDiskBridge.swift",
                "Models/FileNodeRecord.swift",
                "Models/FileTreeStore.swift",
                "Models/ScanProgress.swift",
                "Models/ScanSnapshot.swift",
                "Models/ScanTarget.swift",
                "Models/TrashSafetyPolicy.swift",
                "Services/AtomicDirectoryParallelSummary.swift",
                "Services/AtomicDirectorySummarizer.swift",
                "Services/AtomicDirectorySummaryModels.swift",
                "Services/AtomicDirectorySummaryPool.swift",
                "Services/AtomicDirectorySummaryProbe.swift",
                "Services/AtomicDirectorySummaryWalker.swift",
                "Services/BulkDirectoryEnumerator.swift",
                "Services/CancellableSort.swift",
                "Services/FileSystemEventHistory.swift",
                "Services/PackageClassifier.swift",
                "Services/ScanDiagnostics.swift",
                "Services/ScanDirectoryDescriptorPool.swift",
                "Services/ScanDirectoryEntryFilter.swift",
                "Services/ScanEngine.swift",
                "Services/ScanExclusionMatcher.swift",
                "Services/ScanIncrementalModels.swift",
                "Services/ScanIntegerMath.swift",
                "Services/ScanMetadataLoader.swift",
                "Services/ScanWarningFactory.swift",
                "Services/SharedAllocationDeduplicator.swift",
                "Services/SharedAllocationOwnerAccumulator.swift",
                "Services/VolumeCapacityAccounting.swift"
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
