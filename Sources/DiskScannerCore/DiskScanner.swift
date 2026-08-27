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

    public init(
        filesVisited: Int,
        directoriesVisited: Int,
        bytesDiscovered: Int64,
        currentPath: String,
        fractionCompleted: Double
    ) {
        self.filesVisited = filesVisited
        self.directoriesVisited = directoriesVisited
        self.bytesDiscovered = bytesDiscovered
        self.currentPath = currentPath
        self.fractionCompleted = fractionCompleted
    }

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

public enum DiskScanTrashSafety {
    public static func protectedRootPath(for url: URL) -> String? {
        ScanBackendTrashSafety.protectedRootPath(for: url)
    }
}

public struct DiskScanCompositeSource: Sendable {
    public let name: String
    public let snapshot: DiskScanSnapshot

    public init(name: String, snapshot: DiskScanSnapshot) {
        self.name = name
        self.snapshot = snapshot
    }
}

public struct DiskScanCompositeGroup: Sendable {
    public let name: String
    public let url: URL
    public let sources: [DiskScanCompositeSource]

    public init(name: String, url: URL, sources: [DiskScanCompositeSource]) {
        self.name = name
        self.url = url
        self.sources = sources
    }
}

public struct DiskScanSnapshot: Sendable {
    public let rootID: String
    public let issues: [DiskScanIssue]
    public let statistics: DiskScanStatistics
    public let capacity: DiskVolumeCapacity?
    public let startedAt: Date
    public let finishedAt: Date?

    private struct CompositeStorage: Sendable {
        let root: DiskFileNode
        let syntheticNodes: [String: DiskFileNode]
        let presentedRootNodes: [String: DiskFileNode]
        let backendSnapshots: [ScanBackendSnapshot]
        let nodeCount: Int
    }

    private enum Storage: Sendable {
        case backend(ScanBackendSnapshot)
        case composite(CompositeStorage)
    }

    private let storage: Storage

    public var nodeCount: Int {
        switch storage {
        case .backend(let backendSnapshot):
            return backendSnapshot.nodeCount
        case .composite(let composite):
            return composite.nodeCount
        }
    }

    public var root: DiskFileNode? {
        switch storage {
        case .backend(let backendSnapshot):
            return backendSnapshot.root
        case .composite(let composite):
            return composite.root
        }
    }

    public func node(id: String) -> DiskFileNode? {
        switch storage {
        case .backend(let backendSnapshot):
            return backendSnapshot.node(id: id)
        case .composite(let composite):
            if let syntheticNode = composite.syntheticNodes[id] {
                return syntheticNode
            }
            if let presentedNode = composite.presentedRootNodes[id] {
                return presentedNode
            }
            for backendSnapshot in composite.backendSnapshots {
                if let node = backendSnapshot.node(id: id) {
                    return node
                }
            }
            return nil
        }
    }

    public func children(of nodeID: String) -> [DiskFileNode] {
        switch storage {
        case .backend(let backendSnapshot):
            return backendSnapshot.children(of: nodeID)
        case .composite(let composite):
            if let syntheticNode = composite.syntheticNodes[nodeID] {
                return syntheticNode.childIDs.compactMap { node(id: $0) }
            }
            for backendSnapshot in composite.backendSnapshots where backendSnapshot.node(id: nodeID) != nil {
                return backendSnapshot.children(of: nodeID).map {
                    composite.presentedRootNodes[$0.id] ?? $0
                }
            }
            return []
        }
    }

    /// Removes a subtree from an immutable scan result after the corresponding filesystem item
    /// has successfully moved to Trash. Composite scans fall back to a rescan at the UI layer.
    public func removingNode(id: String) -> DiskScanSnapshot? {
        guard case .backend(let backendSnapshot) = storage,
              let updated = backendSnapshot.removingNode(id: id) else { return nil }

        return DiskScanSnapshot(
            rootID: updated.rootID,
            issues: updated.warnings.map {
                DiskScanIssue(
                    id: $0.id,
                    path: $0.path,
                    message: $0.message,
                    kind: $0.kind == .permissionDenied ? .permissionDenied : .fileSystem
                )
            },
            statistics: DiskScanStatistics(
                allocatedBytes: updated.statistics.allocatedBytes,
                logicalBytes: updated.statistics.logicalBytes,
                fileCount: updated.statistics.fileCount,
                directoryCount: updated.statistics.directoryCount,
                accessibleItemCount: updated.statistics.accessibleItemCount,
                inaccessibleItemCount: updated.statistics.inaccessibleItemCount
            ),
            capacity: updated.capacity.map {
                DiskVolumeCapacity(totalBytes: $0.totalBytes, availableBytes: $0.availableBytes)
            },
            startedAt: updated.startedAt,
            finishedAt: updated.finishedAt,
            backendSnapshot: updated
        )
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
        self.storage = .backend(backendSnapshot)
    }

    public static func composite(
        id: String,
        name: String,
        url: URL,
        groups: [DiskScanCompositeGroup]
    ) -> DiskScanSnapshot? {
        let populatedGroups = groups.compactMap { group -> (DiskScanCompositeGroup, [(DiskScanCompositeSource, ScanBackendSnapshot)])? in
            let sources = group.sources.compactMap { source in
                source.snapshot.backendSnapshot.map { (source, $0) }
            }
            return sources.isEmpty ? nil : (group, sources)
        }
        guard !populatedGroups.isEmpty else { return nil }

        var syntheticNodes: [String: DiskFileNode] = [:]
        var presentedRootNodes: [String: DiskFileNode] = [:]
        var backendSnapshots: [ScanBackendSnapshot] = []
        var groupNodes: [DiskFileNode] = []

        for (index, item) in populatedGroups.enumerated() {
            let group = item.0
            let sources = item.1
            let groupID = "\(id)/group/\(index)"
            let sourceRoots = sources.compactMap { source, backendSnapshot -> DiskFileNode? in
                guard let sourceRoot = backendSnapshot.root else { return nil }
                backendSnapshots.append(backendSnapshot)
                let presentedRoot = sourceRoot.replacingPresentation(
                    name: source.name,
                    parentID: groupID
                )
                presentedRootNodes[presentedRoot.id] = presentedRoot
                return presentedRoot
            }
            guard !sourceRoots.isEmpty else { continue }

            if sourceRoots.count == 1, let sourceRoot = sourceRoots.first {
                let presentedRoot = sourceRoot.replacingPresentation(
                    name: group.name,
                    parentID: id
                )
                presentedRootNodes[presentedRoot.id] = presentedRoot
                groupNodes.append(presentedRoot)
                continue
            }

            let groupNode = DiskFileNode.syntheticDirectory(
                id: groupID,
                url: group.url,
                name: group.name,
                childIDs: sourceRoots.map(\.id),
                parentID: id,
                allocatedBytes: sourceRoots.reduce(0) { $0 + $1.allocatedBytes },
                logicalBytes: sourceRoots.reduce(0) { $0 + $1.logicalBytes },
                descendantFileCount: sourceRoots.reduce(0) { $0 + $1.descendantFileCount },
                isAccessible: sourceRoots.allSatisfy(\.isAccessible),
                lastModified: sourceRoots.compactMap(\.lastModified).max()
            )
            syntheticNodes[groupID] = groupNode
            groupNodes.append(groupNode)
        }

        guard !groupNodes.isEmpty else { return nil }

        let root = DiskFileNode.syntheticDirectory(
            id: id,
            url: url,
            name: name,
            childIDs: groupNodes.map(\.id),
            parentID: nil,
            allocatedBytes: groupNodes.reduce(0) { $0 + $1.allocatedBytes },
            logicalBytes: groupNodes.reduce(0) { $0 + $1.logicalBytes },
            descendantFileCount: groupNodes.reduce(0) { $0 + $1.descendantFileCount },
            isAccessible: groupNodes.allSatisfy(\.isAccessible),
            lastModified: groupNodes.compactMap(\.lastModified).max()
        )
        syntheticNodes[id] = root

        let sourceSnapshots = populatedGroups.flatMap { $0.1.map(\.0.snapshot) }
        let statistics = DiskScanStatistics(
            allocatedBytes: sourceSnapshots.reduce(0) { $0 + $1.statistics.allocatedBytes },
            logicalBytes: sourceSnapshots.reduce(0) { $0 + $1.statistics.logicalBytes },
            fileCount: sourceSnapshots.reduce(0) { $0 + $1.statistics.fileCount },
            directoryCount: sourceSnapshots.reduce(0) { $0 + $1.statistics.directoryCount },
            accessibleItemCount: sourceSnapshots.reduce(0) { $0 + $1.statistics.accessibleItemCount },
            inaccessibleItemCount: sourceSnapshots.reduce(0) { $0 + $1.statistics.inaccessibleItemCount }
        )
        let compositeStorage = CompositeStorage(
            root: root,
            syntheticNodes: syntheticNodes,
            presentedRootNodes: presentedRootNodes,
            backendSnapshots: backendSnapshots,
            nodeCount: syntheticNodes.count + backendSnapshots.reduce(0) { $0 + $1.nodeCount }
        )

        return DiskScanSnapshot(
            rootID: id,
            issues: sourceSnapshots.flatMap(\.issues),
            statistics: statistics,
            capacity: nil,
            startedAt: sourceSnapshots.map(\.startedAt).min() ?? Date(),
            finishedAt: sourceSnapshots.compactMap(\.finishedAt).max(),
            storage: .composite(compositeStorage)
        )
    }

    private init(
        rootID: String,
        issues: [DiskScanIssue],
        statistics: DiskScanStatistics,
        capacity: DiskVolumeCapacity?,
        startedAt: Date,
        finishedAt: Date?,
        storage: Storage
    ) {
        self.rootID = rootID
        self.issues = issues
        self.statistics = statistics
        self.capacity = capacity
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.storage = storage
    }

    private var backendSnapshot: ScanBackendSnapshot? {
        guard case .backend(let backendSnapshot) = storage else { return nil }
        return backendSnapshot
    }
}

private extension DiskFileNode {
    static func syntheticDirectory(
        id: String,
        url: URL,
        name: String,
        childIDs: [String],
        parentID: String?,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        descendantFileCount: Int,
        isAccessible: Bool,
        lastModified: Date?
    ) -> DiskFileNode {
        DiskFileNode(
            id: id,
            url: url,
            name: name,
            childIDs: childIDs,
            parentID: parentID,
            isDirectory: true,
            isSymbolicLink: false,
            isPackage: false,
            isAccessible: isAccessible,
            isSynthetic: true,
            wasSummarized: false,
            allocatedBytes: allocatedBytes,
            logicalBytes: logicalBytes,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            linkCount: 1,
            mayShareAPFSBlocks: false
        )
    }

    func replacingPresentation(name: String, parentID: String) -> DiskFileNode {
        DiskFileNode(
            id: id,
            url: url,
            name: name,
            childIDs: childIDs,
            parentID: parentID,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSynthetic: isSynthetic,
            wasSummarized: wasSummarized,
            allocatedBytes: allocatedBytes,
            logicalBytes: logicalBytes,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            linkCount: linkCount,
            mayShareAPFSBlocks: mayShareAPFSBlocks
        )
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
