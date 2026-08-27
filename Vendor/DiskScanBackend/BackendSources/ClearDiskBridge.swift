import Foundation

public nonisolated struct ScanBackendScanOptions: Sendable {
    public let rootURL: URL
    public let includeHiddenItems: Bool
    public let expandPackages: Bool
    public let exclusionPatterns: [String]
    public let preservedDirectoryURLs: [URL]

    public init(
        rootURL: URL,
        includeHiddenItems: Bool = false,
        expandPackages: Bool = false,
        exclusionPatterns: [String] = [],
        preservedDirectoryURLs: [URL] = []
    ) {
        self.rootURL = rootURL
        self.includeHiddenItems = includeHiddenItems
        self.expandPackages = expandPackages
        self.exclusionPatterns = exclusionPatterns
        self.preservedDirectoryURLs = preservedDirectoryURLs
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
    public let parentID: String?
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

    public init(
        id: String,
        url: URL,
        name: String,
        childIDs: [String],
        parentID: String?,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isPackage: Bool,
        isAccessible: Bool,
        isSynthetic: Bool,
        wasSummarized: Bool,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        linkCount: UInt64,
        mayShareAPFSBlocks: Bool
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.childIDs = childIDs
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.isAccessible = isAccessible
        self.isSynthetic = isSynthetic
        self.wasSummarized = wasSummarized
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.descendantFileCount = descendantFileCount
        self.lastModified = lastModified
        self.linkCount = linkCount
        self.mayShareAPFSBlocks = mayShareAPFSBlocks
    }
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

/// Product-facing access to the backend's root protection policy. Callers may offer Trash
/// actions for ordinary scan results without duplicating macOS firmlink and volume safeguards.
public nonisolated enum ScanBackendTrashSafety {
    public static func protectedRootPath(for url: URL) -> String? {
        TrashSafetyPolicy.blockReason(for: url)?.path
    }
}

public nonisolated struct ScanBackendSnapshot: Sendable {
    public let rootID: String
    public let warnings: [ScanBackendWarning]
    public let statistics: ScanBackendStatistics
    public let capacity: ScanBackendCapacity?
    public let startedAt: Date
    public let finishedAt: Date?

    private let storage: ScanSnapshot

    public var nodeCount: Int {
        storage.treeStore.nodeCount
    }

    public var root: ScanBackendNode? {
        node(id: rootID)
    }

    public func node(id: String) -> ScanBackendNode? {
        guard let record = storage.treeStore.node(id: id) else { return nil }
        return Self.export(record, from: storage.treeStore)
    }

    public func children(of nodeID: String) -> [ScanBackendNode] {
        storage.treeStore.children(of: nodeID).map {
            Self.export($0, from: storage.treeStore)
        }
    }

    /// Returns an updated immutable snapshot after a successfully trashed subtree.
    public func removingNode(id: String) -> ScanBackendSnapshot? {
        guard let updated = storage.removingNode(id: id) else { return nil }
        let stats = updated.aggregateStats
        let updatedCapacity = updated.volumeCapacity.map {
            ScanBackendCapacity(
                totalBytes: $0.totalCapacity,
                availableBytes: $0.availableCapacity
            )
        }

        return ScanBackendSnapshot(
            storage: updated,
            warnings: updated.scanWarnings.map { warning in
                ScanBackendWarning(
                    id: warning.id,
                    path: warning.path,
                    message: warning.message,
                    kind: warning.category == .permissionDenied ? .permissionDenied : .fileSystem
                )
            },
            statistics: ScanBackendStatistics(
                allocatedBytes: stats.totalAllocatedSize,
                logicalBytes: stats.totalLogicalSize,
                fileCount: stats.fileCount,
                directoryCount: stats.directoryCount,
                accessibleItemCount: stats.accessibleItemCount,
                inaccessibleItemCount: stats.inaccessibleItemCount
            ),
            capacity: updatedCapacity
        )
    }

    fileprivate init(
        storage: ScanSnapshot,
        warnings: [ScanBackendWarning],
        statistics: ScanBackendStatistics,
        capacity: ScanBackendCapacity?
    ) {
        self.rootID = storage.treeStore.rootID
        self.warnings = warnings
        self.statistics = statistics
        self.capacity = capacity
        self.startedAt = storage.startedAt
        self.finishedAt = storage.finishedAt
        self.storage = storage
    }

    private static func export(
        _ node: FileNodeRecord,
        from treeStore: FileTreeStore
    ) -> ScanBackendNode {
        ScanBackendNode(
            id: node.id,
            url: node.url,
            name: node.name,
            childIDs: treeStore.childIDs(of: node.id),
            parentID: treeStore.parentID(of: node.id),
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
}

public nonisolated enum ScanBackendEvent: Sendable {
    case progress(ScanBackendProgress)
    case warning(ScanBackendWarning)
    case completed(ScanBackendSnapshot)
}

public final class FullDiskScannerBackend {
    private let engine = ScanEngine()

    public nonisolated init() {}

    public nonisolated func scan(
        options: ScanBackendScanOptions
    ) -> AsyncThrowingStream<ScanBackendEvent, Error> {
        let target = ScanTarget(url: options.rootURL)
        let scanOptions = ScanOptions(
            includeHiddenFiles: options.includeHiddenItems,
            treatPackagesAsDirectories: options.expandPackages,
            exclusionPatterns: options.exclusionPatterns,
            exclusionRootPath: target.url.path,
            autoSummaryProtectedPaths: Self.autoSummaryProtectedPaths(
                preserving: options.preservedDirectoryURLs,
                under: target.url.path
            )
        )
        let source = engine.scan(target: target, options: scanOptions)

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var latestProgress: ScanBackendProgress?
                do {
                    for try await event in source {
                        switch event {
                        case .executionMode:
                            continue
                        case .progress(let metrics):
                            var mapped = Self.makeProgress(metrics)
                            if mapped.fractionCompleted >= 1 {
                                mapped = ScanBackendProgress(
                                    filesVisited: mapped.filesVisited,
                                    directoriesVisited: mapped.directoriesVisited,
                                    bytesDiscovered: mapped.bytesDiscovered,
                                    currentPath: "Preparing visualization…",
                                    fractionCompleted: 0.99
                                )
                            }
                            latestProgress = mapped
                            continuation.yield(.progress(mapped))
                        case .warning(let warning):
                            continuation.yield(.warning(Self.makeWarning(warning)))
                        case .finished(let snapshot):
                            if let latestProgress {
                                continuation.yield(.progress(ScanBackendProgress(
                                    filesVisited: latestProgress.filesVisited,
                                    directoriesVisited: latestProgress.directoriesVisited,
                                    bytesDiscovered: latestProgress.bytesDiscovered,
                                    currentPath: "Preparing visualization…",
                                    fractionCompleted: 0.995
                                )))
                            }
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

    private nonisolated static func autoSummaryProtectedPaths(
        preserving urls: [URL],
        under rootPath: String
    ) -> Set<String>? {
        guard !urls.isEmpty else { return nil }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.path
        let rootPrefix = root == "/" ? "/" : root + "/"
        var protectedPaths = Set<String>()

        for url in urls {
            var candidate = url.standardizedFileURL.path
            guard candidate == root || candidate.hasPrefix(rootPrefix) else { continue }

            while true {
                protectedPaths.insert(candidate)
                guard candidate != root else { break }
                let parent = URL(fileURLWithPath: candidate, isDirectory: true)
                    .deletingLastPathComponent().standardizedFileURL.path
                guard parent != candidate,
                      parent == root || parent.hasPrefix(rootPrefix) else { break }
                candidate = parent
            }
        }

        return protectedPaths.isEmpty ? nil : protectedPaths
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
        let stats = snapshot.aggregateStats
        let capacity = snapshot.volumeCapacity.map {
            ScanBackendCapacity(
                totalBytes: $0.totalCapacity,
                availableBytes: $0.availableCapacity
            )
        }

        return ScanBackendSnapshot(
            storage: snapshot,
            warnings: snapshot.scanWarnings.map(makeWarning),
            statistics: ScanBackendStatistics(
                allocatedBytes: stats.totalAllocatedSize,
                logicalBytes: stats.totalLogicalSize,
                fileCount: stats.fileCount,
                directoryCount: stats.directoryCount,
                accessibleItemCount: stats.accessibleItemCount,
                inaccessibleItemCount: stats.inaccessibleItemCount
            ),
            capacity: capacity
        )
    }
}
