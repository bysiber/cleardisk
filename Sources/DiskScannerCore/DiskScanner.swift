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

/// A flat tree record. `childIDs` keeps large scans compact and lets the UI request only the
/// branch it is currently displaying instead of materializing a recursive Swift value tree.
public struct DiskFileNode: Identifiable, Sendable {
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
    public let nodesByID: [String: DiskFileNode]
    public let issues: [DiskScanIssue]
    public let statistics: DiskScanStatistics
    public let capacity: DiskVolumeCapacity?
    public let startedAt: Date
    public let finishedAt: Date?

    public var root: DiskFileNode? {
        nodesByID[rootID]
    }

    public func node(id: String) -> DiskFileNode? {
        nodesByID[id]
    }

    public func children(of nodeID: String) -> [DiskFileNode] {
        guard let node = nodesByID[nodeID] else { return [] }
        return node.childIDs.compactMap { nodesByID[$0] }
    }
}

public enum DiskScanEvent: Sendable {
    case progress(DiskScanProgress)
    case issue(DiskScanIssue)
    case completed(DiskScanSnapshot)
}

/// Product-facing boundary for the full-disk scanner. ClearDisk's cache scanner intentionally
/// does not appear in this module; cleanup classification will be layered on top later.
@MainActor
public final class DiskScanner {
    private let backend: FullDiskScannerBackend

    public init() {
        backend = FullDiskScannerBackend()
    }

    public func events(
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
            let task = Task {
                do {
                    for try await event in source {
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
            let nodes = snapshot.nodes.map(map)
            return .completed(
                DiskScanSnapshot(
                    rootID: snapshot.rootID,
                    nodesByID: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
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
                    finishedAt: snapshot.finishedAt
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

    private nonisolated static func map(_ node: ScanBackendNode) -> DiskFileNode {
        DiskFileNode(
            id: node.id,
            url: node.url,
            name: node.name,
            childIDs: node.childIDs,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            isPackage: node.isPackage,
            isAccessible: node.isAccessible,
            isSynthetic: node.isSynthetic,
            wasSummarized: node.wasSummarized,
            allocatedBytes: node.allocatedBytes,
            logicalBytes: node.logicalBytes,
            descendantFileCount: node.descendantFileCount,
            lastModified: node.lastModified,
            linkCount: node.linkCount,
            mayShareAPFSBlocks: node.mayShareAPFSBlocks
        )
    }
}
