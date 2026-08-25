import Foundation
import DiskScanBackend

public struct DiskScanRequest: Sendable {
    public let rootURL: URL
    public let includesHiddenItems: Bool
    public let expandsPackages: Bool
    public let exclusionPatterns: [String]

    public init(
        rootURL: URL,
        includesHiddenItems: Bool = false,
        expandsPackages: Bool = false,
        exclusionPatterns: [String] = []
    ) {
        self.rootURL = rootURL
        self.includesHiddenItems = includesHiddenItems
        self.expandsPackages = expandsPackages
        self.exclusionPatterns = exclusionPatterns
    }
}

public struct DiskScanProgress: Sendable {
    public let filesVisited: Int
    public let directoriesVisited: Int
    public let bytesDiscovered: Int64
    public let currentPath: String
    public let fractionCompleted: Double

    public var visitedItemCount: Int {
        filesVisited + directoriesVisited
    }
}

public struct DiskScanIssue: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case permissionDenied
        case fileSystem
    }

    public let id: UUID
    public let path: String
    public let message: String
    public let kind: Kind
}

/// A flat tree record. Sharing the backend's immutable value avoids retaining a
/// second copy of every file just to rename the type at the product boundary.
public typealias DiskFileNode = ScanBackendNode

public struct DiskScanStatistics: Sendable {
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let accessibleItemCount: Int
    public let inaccessibleItemCount: Int
}

public struct DiskVolumeCapacity: Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public var usedBytes: Int64 {
        max(totalBytes - availableBytes, 0)
    }
}

public struct DiskScanSnapshot: Sendable {
    public let rootID: String
    public let issues: [DiskScanIssue]
    public let statistics: DiskScanStatistics
    public let capacity: DiskVolumeCapacity?
    public let startedAt: Date
    public let finishedAt: Date?

    private let backendSnapshot: ScanBackendSnapshot

    public var nodeCount: Int {
        backendSnapshot.nodeCount
    }

    public var root: DiskFileNode? {
        backendSnapshot.root
    }

    public func node(id: String) -> DiskFileNode? {
        backendSnapshot.node(id: id)
    }

    public func children(of nodeID: String) -> [DiskFileNode] {
        backendSnapshot.children(of: nodeID)
    }

    fileprivate init(
        rootID: String,
        issues: [DiskScanIssue],
        statistics: DiskScanStatistics,
        capacity: DiskVolumeCapacity?,
        startedAt: Date,
        finishedAt: Date?,
        backendSnapshot: ScanBackendSnapshot
    ) {
        self.rootID = rootID
        self.issues = issues
        self.statistics = statistics
        self.capacity = capacity
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.backendSnapshot = backendSnapshot
    }
}

public enum DiskScanEvent: Sendable {
    case progress(DiskScanProgress)
    case issue(DiskScanIssue)
    case completed(DiskScanSnapshot)
}

/// Product-facing boundary for the full-disk scanner. ClearDisk's cache scanner intentionally
/// does not appear in this module; cleanup classification will be layered on top later.
public final class DiskScanner {
    private let backend: FullDiskScannerBackend

    public nonisolated init() {
        backend = FullDiskScannerBackend()
    }

    public nonisolated func events(
        for request: DiskScanRequest
    ) -> AsyncThrowingStream<DiskScanEvent, Error> {
        let source = backend.scan(
            options: ScanBackendScanOptions(
                rootURL: request.rootURL,
                includeHiddenItems: request.includesHiddenItems,
                expandPackages: request.expandsPackages,
                exclusionPatterns: request.exclusionPatterns
            )
        )

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await event in source {
                        if case .completed(let snapshot) = event {
                            continuation.yield(.progress(DiskScanProgress(
                                filesVisited: snapshot.statistics.fileCount,
                                directoriesVisited: snapshot.statistics.directoryCount,
                                bytesDiscovered: snapshot.statistics.allocatedBytes,
                                currentPath: "Building disk map…",
                                fractionCompleted: 0.998
                            )))
                        }
                        continuation.yield(Self.map(event))
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

    private nonisolated static func map(_ event: ScanBackendEvent) -> DiskScanEvent {
        switch event {
        case .progress(let progress):
            return .progress(
                DiskScanProgress(
                    filesVisited: progress.filesVisited,
                    directoriesVisited: progress.directoriesVisited,
                    bytesDiscovered: progress.bytesDiscovered,
                    currentPath: progress.currentPath,
                    fractionCompleted: progress.fractionCompleted
                )
            )
        case .warning(let warning):
            return .issue(map(warning))
        case .completed(let snapshot):
            return .completed(
                DiskScanSnapshot(
                    rootID: snapshot.rootID,
                    issues: snapshot.warnings.map(map),
                    statistics: DiskScanStatistics(
                        allocatedBytes: snapshot.statistics.allocatedBytes,
                        logicalBytes: snapshot.statistics.logicalBytes,
                        fileCount: snapshot.statistics.fileCount,
                        directoryCount: snapshot.statistics.directoryCount,
                        accessibleItemCount: snapshot.statistics.accessibleItemCount,
                        inaccessibleItemCount: snapshot.statistics.inaccessibleItemCount
                    ),
                    capacity: snapshot.capacity.map {
                        DiskVolumeCapacity(
                            totalBytes: $0.totalBytes,
                            availableBytes: $0.availableBytes
                        )
                    },
                    startedAt: snapshot.startedAt,
                    finishedAt: snapshot.finishedAt,
                    backendSnapshot: snapshot
                )
            )
        }
    }

    private nonisolated static func map(_ warning: ScanBackendWarning) -> DiskScanIssue {
        DiskScanIssue(
            id: warning.id,
            path: warning.path,
            message: warning.message,
            kind: warning.kind == .permissionDenied ? .permissionDenied : .fileSystem
        )
    }

}
