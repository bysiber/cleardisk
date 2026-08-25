import Foundation

public nonisolated struct ScanBackendScanOptions: Sendable {
    public let rootURL: URL
    public let includeHiddenItems: Bool
    public let expandPackages: Bool
    public let exclusionPatterns: [String]

    public init(
        rootURL: URL,
        includeHiddenItems: Bool = false,
        expandPackages: Bool = false,
        exclusionPatterns: [String] = []
    ) {
        self.rootURL = rootURL
        self.includeHiddenItems = includeHiddenItems
        self.expandPackages = expandPackages
        self.exclusionPatterns = exclusionPatterns
    }
}

public nonisolated struct ScanBackendProgress: Sendable {
    public let filesVisited: Int
    public let directoriesVisited: Int
    public let bytesDiscovered: Int64
    public let currentPath: String
    public let fractionCompleted: Double
}

public nonisolated enum ScanBackendWarningKind: String, Sendable {
    case permissionDenied
    case fileSystem
}

public nonisolated struct ScanBackendWarning: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let message: String
    public let kind: ScanBackendWarningKind
}

public nonisolated struct ScanBackendNode: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let childIDs: [String]
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isPackage: Bool
    public let isAccessible: Bool
    public let isSynthetic: Bool
    public let wasSummarized: Bool
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let descendantFileCount: Int
    public let lastModified: Date?
    public let linkCount: UInt64
    public let mayShareAPFSBlocks: Bool
}

public nonisolated struct ScanBackendStatistics: Sendable {
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let accessibleItemCount: Int
    public let inaccessibleItemCount: Int
}

public nonisolated struct ScanBackendCapacity: Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public var usedBytes: Int64 {
        max(totalBytes - availableBytes, 0)
    }
}

public nonisolated struct ScanBackendSnapshot: Sendable {
    public let rootID: String
    public let nodes: [ScanBackendNode]
    public let warnings: [ScanBackendWarning]
    public let statistics: ScanBackendStatistics
    public let capacity: ScanBackendCapacity?
    public let startedAt: Date
    public let finishedAt: Date?
}

public nonisolated enum ScanBackendEvent: Sendable {
    case progress(ScanBackendProgress)
    case warning(ScanBackendWarning)
    case completed(ScanBackendSnapshot)
}

@MainActor
public final class FullDiskScannerBackend {
    private let engine = ScanEngine()

    public init() {}

    public func scan(
        options: ScanBackendScanOptions
    ) -> AsyncThrowingStream<ScanBackendEvent, Error> {
        let target = ScanTarget(url: options.rootURL)
        let scanOptions = ScanOptions(
            includeHiddenFiles: options.includeHiddenItems,
            treatPackagesAsDirectories: options.expandPackages,
            exclusionPatterns: options.exclusionPatterns,
            exclusionRootPath: target.url.path
        )
        let source = engine.scan(target: target, options: scanOptions)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        switch event {
                        case .executionMode:
                            continue
                        case .progress(let metrics):
                            continuation.yield(.progress(Self.makeProgress(metrics)))
                        case .warning(let warning):
                            continuation.yield(.warning(Self.makeWarning(warning)))
                        case .finished(let snapshot):
                            continuation.yield(.completed(Self.makeSnapshot(snapshot)))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private nonisolated static func makeProgress(_ metrics: ScanMetrics) -> ScanBackendProgress {
        ScanBackendProgress(
            filesVisited: metrics.filesVisited,
            directoriesVisited: metrics.directoriesVisited,
            bytesDiscovered: metrics.bytesDiscovered,
            currentPath: metrics.currentPath,
            fractionCompleted: metrics.progressFraction
        )
    }

    private nonisolated static func makeWarning(_ warning: ScanWarning) -> ScanBackendWarning {
        ScanBackendWarning(
            id: warning.id,
            path: warning.path,
            message: warning.message,
            kind: warning.category == .permissionDenied ? .permissionDenied : .fileSystem
        )
    }

    private nonisolated static func makeSnapshot(_ snapshot: ScanSnapshot) -> ScanBackendSnapshot {
        let childIDs = snapshot.treeStore.childIDsByID
        let nodes = snapshot.treeStore.nodesByID.values
            .map { node in
                ScanBackendNode(
                    id: node.id,
                    url: node.url,
                    name: node.name,
                    childIDs: childIDs[node.id] ?? [],
                    isDirectory: node.isDirectory,
                    isSymbolicLink: node.isSymbolicLink,
                    isPackage: node.isPackage,
                    isAccessible: node.isAccessible,
                    isSynthetic: node.isSynthetic,
                    wasSummarized: node.isAutoSummarized,
                    allocatedBytes: node.allocatedSize,
                    logicalBytes: node.logicalSize,
                    descendantFileCount: node.descendantFileCount,
                    lastModified: node.lastModified,
                    linkCount: node.linkCount,
                    mayShareAPFSBlocks: node.mayShareDataBlocks
                )
            }
            .sorted { $0.id < $1.id }
        let stats = snapshot.aggregateStats
        let capacity = snapshot.volumeCapacity.map {
            ScanBackendCapacity(
                totalBytes: $0.totalCapacity,
                availableBytes: $0.availableCapacity
            )
        }

        return ScanBackendSnapshot(
            rootID: snapshot.treeStore.rootID,
            nodes: nodes,
            warnings: snapshot.scanWarnings.map(makeWarning),
            statistics: ScanBackendStatistics(
                allocatedBytes: stats.totalAllocatedSize,
                logicalBytes: stats.totalLogicalSize,
                fileCount: stats.fileCount,
                directoryCount: stats.directoryCount,
                accessibleItemCount: stats.accessibleItemCount,
                inaccessibleItemCount: stats.inaccessibleItemCount
            ),
            capacity: capacity,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt
        )
    }
}
