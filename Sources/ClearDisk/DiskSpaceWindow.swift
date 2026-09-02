import AppKit
import DiskScannerCore
import SwiftUI

struct DiskSpaceLocation: Identifiable, Hashable {
    enum Kind: Hashable {
        case startupDisk
        case externalVolume
        case favorite
    }

    let id: String
    let name: String
    let url: URL
    let icon: String
    let kind: Kind
    let subtitle: String
}

private enum DiskSpaceScanError: LocalizedError {
    case noTemporaryLocations
    case noTemporaryFiles

    var errorDescription: String? {
        switch self {
        case .noTemporaryLocations:
            return L("No temporary locations are available on this Mac.")
        case .noTemporaryFiles:
            return L("Temporary locations could not be analyzed.")
        }
    }
}

enum DiskSpaceTrashAlert: Identifiable {
    case confirmation(nodeID: String, name: String, size: Int64, path: String)
    case failure(id: UUID, message: String)

    var id: String {
        switch self {
        case .confirmation(let nodeID, _, _, _):
            return "confirmation:\(nodeID)"
        case .failure(let id, _):
            return "failure:\(id.uuidString)"
        }
    }
}

enum DiskSpacePresentationSurface {
    case compact
    case window
}

@MainActor
final class DiskSpaceStore: ObservableObject {
    private static let temporaryFilesLocationID = "cleardisk://temporary-files"
    /// Keep only a shallow, useful slice of each scan in memory. Directories
    /// beyond this boundary remain accurate summary nodes and are scanned on
    /// demand when opened.
    private static let maximumMaterializedDepth = 2
    /// Every Back destination must be restorable without touching the filesystem. Keep the
    /// original location plus a short trail of recent shallow snapshots; if a user navigates
    /// unusually deep, old intermediate levels are skipped instead of being rescanned.
    private static let maximumNavigationHistoryDepth = 4
    /// Switching cards should not repeatedly scan the same large location. Two shallow inactive
    /// results are enough for fast back-and-forth without returning to unbounded snapshot growth.
    private static let maximumCachedLocationSnapshots = 2

    private struct ScanNavigationEntry {
        let rootURL: URL
        let focusedNodeID: String
        let scansVirtualTemporaryLocation: Bool
        let snapshot: DiskScanSnapshot
        let issues: [DiskScanIssue]
        let scannedRootPath: String
    }

    private struct CachedLocationScan {
        let snapshot: DiskScanSnapshot
        let issues: [DiskScanIssue]
        let scannedRootPath: String
        let rootURL: URL
        let scansVirtualTemporaryLocation: Bool
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    enum ScanPresentation: Equatable {
        case analysis
        case navigation
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: DiskScanProgress?
    @Published private(set) var snapshot: DiskScanSnapshot?
    @Published private(set) var issues: [DiskScanIssue] = []
    @Published private(set) var locations: [DiskSpaceLocation] = []
    @Published var selectedLocationID = "/"
    @Published private(set) var focusedNodeID: String?
    @Published private(set) var selectedNodeID: String?
    @Published private(set) var deletingNodeIDs: Set<String> = []
    @Published private(set) var trashAlert: DiskSpaceTrashAlert?
    @Published private(set) var trashAlertSurface: DiskSpacePresentationSurface?
    @Published private(set) var analyzedLocationBytes: [String: Int64] = [:]
    @Published private(set) var scanPresentation: ScanPresentation = .analysis

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var scannedRootPath: String?
    private var activeScanRootURL: URL?
    private var activeScanIsVirtualTemporaryLocation = false
    private var scanNavigationHistory: [ScanNavigationEntry] = []
    private var pendingRestoreFocusID: String?
    private var lastListActivationAt = Date.distantPast
    private var cachedLocationScans: [String: CachedLocationScan] = [:]
    private var cachedLocationOrder: [String] = []

    init() {
        reloadLocations()
    }

    deinit {
        scanTask?.cancel()
    }

    var selectedLocation: DiskSpaceLocation {
        locations.first(where: { $0.id == selectedLocationID })
            ?? locations.first
            ?? Self.startupDiskLocation()
    }

    var selectedLocationDetail: String {
        if let activeScanRootURL,
           scannedRootPath != Self.temporaryFilesLocationID {
            return activeScanRootURL.path
        }
        return selectedLocation.id == Self.temporaryFilesLocationID
            ? selectedLocation.subtitle
            : selectedLocation.url.path
    }

    var displayedNode: DiskFileNode? {
        guard let snapshot else { return nil }
        if let focusedNodeID, let focusedNode = snapshot.node(id: focusedNodeID) {
            return focusedNode
        }
        return locationRootNode
    }

    var displayedChildren: [DiskFileNode] {
        guard let snapshot, let displayedNode else { return [] }
        return snapshot.children(of: displayedNode.id)
            .filter { $0.allocatedBytes > 0 }
            .sorted { lhs, rhs in
                if lhs.allocatedBytes == rhs.allocatedBytes {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
    }

    var hasResultsForSelection: Bool {
        guard snapshot != nil, phase == .finished else { return false }
        return !scanNavigationHistory.isEmpty || locationRootNode != nil
    }

    var selectedNode: DiskFileNode? {
        guard let selectedNodeID else { return nil }
        return snapshot?.node(id: selectedNodeID)
    }

    var breadcrumbNodes: [DiskFileNode] {
        guard let snapshot, let displayedNode, let navigationRoot = snapshot.root else { return [] }

        var result = [displayedNode]
        var currentID = displayedNode.id
        while currentID != navigationRoot.id,
              let parentID = snapshot.node(id: currentID)?.parentID,
              let parent = snapshot.node(id: parentID) {
            result.append(parent)
            currentID = parentID
        }
        return result.reversed()
    }

    var canNavigateUp: Bool {
        guard let snapshot, let displayedNode else {
            return !scanNavigationHistory.isEmpty
        }
        return displayedNode.id != snapshot.rootID || !scanNavigationHistory.isEmpty
    }

    var isLoadingNavigation: Bool {
        phase == .scanning && scanPresentation == .navigation
    }

    var navigationLoadingTitle: String {
        let name = activeScanRootURL?.lastPathComponent ?? ""
        return name.isEmpty ? selectedLocation.name : name
    }

    var navigationLoadingPath: String? {
        guard let path = activeScanRootURL?.path, !path.isEmpty else { return nil }
        return abbreviatedPath(path)
    }

    func reloadLocations() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var values = [Self.startupDiskLocation()]

        let volumeKeys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: volumeKeys,
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in mountedVolumes where volume.path != "/" {
            let valuesForVolume = try? volume.resourceValues(forKeys: Set(volumeKeys))
            guard valuesForVolume?.volumeIsInternal != true else { continue }
            let name = valuesForVolume?.volumeName ?? volume.lastPathComponent
            values.append(
                DiskSpaceLocation(
                    id: normalizedPath(volume.path),
                    name: name,
                    url: volume,
                    icon: "externaldrive.fill",
                    kind: .externalVolume,
                    subtitle: L("External Volume")
                )
            )
        }

        let favoriteDefinitions: [(String, URL, String)] = [
            ("Home", home, "house.fill"),
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true), "menubar.dock.rectangle"),
            ("Documents", home.appendingPathComponent("Documents", isDirectory: true), "doc.fill"),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true), "arrow.down.circle.fill")
        ]
        values.append(contentsOf: Self.locations(
            from: favoriteDefinitions,
            fileManager: fileManager
        ))

        values.append(
            DiskSpaceLocation(
                id: Self.temporaryFilesLocationID,
                name: L("Temporary Files"),
                url: fileManager.temporaryDirectory,
                icon: "clock.arrow.circlepath",
                kind: .favorite,
                subtitle: L("User, shared, persistent, and sandboxed app temporary files")
            )
        )

        values.append(contentsOf: Self.locations(
            from: [
                ("Applications", URL(fileURLWithPath: "/Applications", isDirectory: true), "app.fill"),
                ("Library", home.appendingPathComponent("Library", isDirectory: true), "books.vertical.fill")
            ],
            fileManager: fileManager
        ))

        locations = values
        if !values.contains(where: { $0.id == selectedLocationID }) {
            selectedLocationID = "/"
        }
    }

    private static func locations(
        from definitions: [(String, URL, String)],
        fileManager: FileManager
    ) -> [DiskSpaceLocation] {
        definitions.compactMap { name, url, icon in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return DiskSpaceLocation(
                id: normalizedPath(url.path),
                name: name,
                url: url,
                icon: icon,
                kind: .favorite,
                subtitle: abbreviatedPath(url.path)
            )
        }
    }

    func startScan() {
        scanNavigationHistory.removeAll(keepingCapacity: true)
        cachedLocationScans.removeValue(forKey: selectedLocation.id)
        cachedLocationOrder.removeAll { $0 == selectedLocation.id }
        startScan(
            rootURL: selectedLocation.url,
            restoreFocusID: nil,
            scansVirtualTemporaryLocation: selectedLocation.id == Self.temporaryFilesLocationID
        )
    }

    func rescanCurrentRoot() {
        startScan(
            rootURL: activeScanRootURL ?? selectedLocation.url,
            restoreFocusID: focusedNodeID,
            scansVirtualTemporaryLocation: activeScanIsVirtualTemporaryLocation
        )
    }

    private func startScan(
        rootURL: URL,
        restoreFocusID: String?,
        scansVirtualTemporaryLocation: Bool = false,
        presentation: ScanPresentation = .analysis
    ) {
        stopScan(resetToIdle: false)

        let location = selectedLocation
        let scanID = UUID()
        activeScanID = scanID
        phase = .scanning
        progress = nil
        issues = []
        // A rescan must not retain the previous full-volume tree while a second
        // one is being assembled. On file-heavy Macs that alone can double RAM.
        snapshot = nil
        scannedRootPath = nil
        focusedNodeID = nil
        selectedNodeID = nil
        activeScanRootURL = rootURL
        activeScanIsVirtualTemporaryLocation = scansVirtualTemporaryLocation
        scanPresentation = presentation
        pendingRestoreFocusID = restoreFocusID

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                if scansVirtualTemporaryLocation {
                    try await scanTemporaryFiles(location: location, scanID: scanID)
                } else {
                    try await scanSingleLocation(
                        location,
                        rootURL: rootURL,
                        scanID: scanID
                    )
                }
            } catch is CancellationError {
                if activeScanID == scanID, phase == .scanning { phase = .idle }
            } catch {
                if activeScanID == scanID {
                    phase = .failed(error.localizedDescription)
                }
            }

            if activeScanID == scanID {
                activeScanID = nil
                scanTask = nil
            }
        }
    }

    private func scanSingleLocation(
        _ location: DiskSpaceLocation,
        rootURL: URL,
        scanID: UUID
    ) async throws {
        var collectedIssues: [DiskScanIssue] = []
        let request = DiskScanRequest(
            rootURL: rootURL,
            includesHiddenItems: true,
            expandsPackages: false,
            preservedDirectoryURLs: normalizedPath(rootURL.path) == normalizedPath(location.url.path)
                ? preservedDirectoryURLs(for: location)
                : [],
            maximumMaterializedDepth: Self.maximumMaterializedDepth,
            atomicSummaryWorkerLimit: Self.scanWorkerLimit(for: rootURL),
            directoryClassificationWorkerLimit: Self.scanWorkerLimit(for: rootURL),
            directoryTraversalWorkerLimit: Self.scanWorkerLimit(for: rootURL)
        )

        for try await event in scanner.events(for: request) {
            try ensureScanIsActive(scanID)
            switch event {
            case .progress(let nextProgress):
                progress = nextProgress
            case .issue(let issue):
                // Publishing every permission warning can invalidate the whole
                // SwiftUI hierarchy hundreds of times during a volume scan.
                collectedIssues.append(issue)
            case .completed(let completedSnapshot):
                completeScan(
                    with: completedSnapshot,
                    issues: completedSnapshot.issues.isEmpty
                        ? collectedIssues
                        : completedSnapshot.issues,
                    scannedRootPath: normalizedPath(rootURL.path)
                )
            }
        }
    }

    private func scanTemporaryFiles(
        location: DiskSpaceLocation,
        scanID: UUID
    ) async throws {
        let plan = TemporaryFilesScanPlan.make()
        let sourceCount = plan.reduce(0) { $0 + $1.sources.count }
        guard sourceCount > 0 else {
            throw DiskSpaceScanError.noTemporaryLocations
        }

        var completedSourceCount = 0
        var completedFiles = 0
        var completedDirectories = 0
        var completedBytes: Int64 = 0
        var collectedIssues: [DiskScanIssue] = []
        var completedGroups: [DiskScanCompositeGroup] = []

        for group in plan {
            var completedSources: [DiskScanCompositeSource] = []

            for source in group.sources {
                var sourceSnapshot: DiskScanSnapshot?
                let request = DiskScanRequest(
                    rootURL: source.url,
                    includesHiddenItems: true,
                    expandsPackages: false,
                    maximumMaterializedDepth: Self.maximumMaterializedDepth,
                    atomicSummaryWorkerLimit: Self.scanWorkerLimit(for: source.url),
                    directoryClassificationWorkerLimit: Self.scanWorkerLimit(for: source.url),
                    directoryTraversalWorkerLimit: Self.scanWorkerLimit(for: source.url)
                )

                for try await event in scanner.events(for: request) {
                    try ensureScanIsActive(scanID)
                    switch event {
                    case .progress(let sourceProgress):
                        progress = DiskScanProgress(
                            filesVisited: completedFiles + sourceProgress.filesVisited,
                            directoriesVisited: completedDirectories + sourceProgress.directoriesVisited,
                            bytesDiscovered: completedBytes + sourceProgress.bytesDiscovered,
                            currentPath: sourceProgress.currentPath,
                            fractionCompleted: (
                                Double(completedSourceCount) + sourceProgress.fractionCompleted
                            ) / Double(sourceCount)
                        )
                    case .issue(let issue):
                        collectedIssues.append(issue)
                    case .completed(let completedSnapshot):
                        sourceSnapshot = completedSnapshot
                    }
                }

                if let sourceSnapshot {
                    completedSources.append(
                        DiskScanCompositeSource(name: source.name, snapshot: sourceSnapshot)
                    )
                    completedFiles += sourceSnapshot.statistics.fileCount
                    completedDirectories += sourceSnapshot.statistics.directoryCount
                    completedBytes += sourceSnapshot.statistics.allocatedBytes
                }
                completedSourceCount += 1
            }

            if !completedSources.isEmpty {
                completedGroups.append(
                    DiskScanCompositeGroup(
                        name: group.name,
                        url: group.url,
                        sources: completedSources
                    )
                )
            }
        }

        try ensureScanIsActive(scanID)
        guard let completedSnapshot = DiskScanSnapshot.composite(
            id: Self.temporaryFilesLocationID,
            name: location.name,
            url: location.url,
            groups: completedGroups
        ) else {
            throw DiskSpaceScanError.noTemporaryFiles
        }

        let allIssues = uniqueIssues(completedSnapshot.issues + collectedIssues)
        completeScan(
            with: completedSnapshot,
            issues: allIssues,
            scannedRootPath: location.id
        )
    }

    private func ensureScanIsActive(_ scanID: UUID) throws {
        guard !Task.isCancelled, activeScanID == scanID else {
            throw CancellationError()
        }
    }

    private func completeScan(
        with completedSnapshot: DiskScanSnapshot,
        issues completedIssues: [DiskScanIssue],
        scannedRootPath: String
    ) {
        snapshot = completedSnapshot
        issues = completedIssues
        self.scannedRootPath = scannedRootPath
        if let pendingRestoreFocusID,
           completedSnapshot.node(id: pendingRestoreFocusID) != nil {
            focusedNodeID = pendingRestoreFocusID
        } else {
            focusedNodeID = completedSnapshot.rootID
        }
        self.pendingRestoreFocusID = nil
        selectedNodeID = nil
        progress = nil
        phase = .finished
        recordAnalyzedLocations(in: completedSnapshot, scannedRootPath: scannedRootPath)
    }

    private func uniqueIssues(_ values: [DiskScanIssue]) -> [DiskScanIssue] {
        var seenIDs = Set<UUID>()
        return values.filter { seenIDs.insert($0.id).inserted }
    }

    func stopScan(resetToIdle: Bool = true) {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        if resetToIdle && phase == .scanning {
            phase = .idle
        }
    }

    func selectLocation(_ id: String?) {
        guard let id, locations.contains(where: { $0.id == id }) else { return }
        if id != selectedLocationID {
            cacheCurrentTopLevelLocationScan()
        }
        selectedLocationID = id

        if restoreCachedLocationScan(for: id) {
            return
        }

        if let locationNode = node(forLocationID: id) {
            focusedNodeID = locationNode.id
        } else {
            scanNavigationHistory.removeAll(keepingCapacity: true)
            snapshot = nil
            issues = []
            scannedRootPath = nil
            activeScanRootURL = nil
            activeScanIsVirtualTemporaryLocation = false
            focusedNodeID = nil
            progress = nil
            phase = .idle
        }
        selectedNodeID = nil
        if case .failed = phase { phase = .idle }
    }

    private func cacheCurrentTopLevelLocationScan() {
        guard phase == .finished,
              scanNavigationHistory.isEmpty,
              let snapshot,
              let scannedRootPath,
              let activeScanRootURL,
              let locationID = locationID(forScannedRootPath: scannedRootPath) else { return }

        cachedLocationScans[locationID] = CachedLocationScan(
            snapshot: snapshot,
            issues: issues,
            scannedRootPath: scannedRootPath,
            rootURL: activeScanRootURL,
            scansVirtualTemporaryLocation: activeScanIsVirtualTemporaryLocation
        )
        cachedLocationOrder.removeAll { $0 == locationID }
        cachedLocationOrder.append(locationID)

        while cachedLocationOrder.count > Self.maximumCachedLocationSnapshots {
            let evictedID = cachedLocationOrder.removeFirst()
            cachedLocationScans.removeValue(forKey: evictedID)
        }
    }

    private func restoreCachedLocationScan(for locationID: String) -> Bool {
        guard let cached = cachedLocationScans.removeValue(forKey: locationID) else {
            return false
        }
        cachedLocationOrder.removeAll { $0 == locationID }
        stopScan(resetToIdle: false)
        scanNavigationHistory.removeAll(keepingCapacity: true)
        snapshot = cached.snapshot
        issues = cached.issues
        scannedRootPath = cached.scannedRootPath
        activeScanRootURL = cached.rootURL
        activeScanIsVirtualTemporaryLocation = cached.scansVirtualTemporaryLocation
        focusedNodeID = cached.snapshot.rootID
        selectedNodeID = nil
        pendingRestoreFocusID = nil
        progress = nil
        scanPresentation = .analysis
        phase = .finished
        recordAnalyzedLocations(
            in: cached.snapshot,
            scannedRootPath: cached.scannedRootPath
        )
        return true
    }

    private func locationID(forScannedRootPath path: String) -> String? {
        if path == Self.temporaryFilesLocationID {
            return Self.temporaryFilesLocationID
        }
        return locations.first {
            normalizedPath($0.url.path) == normalizedPath(path)
        }?.id
    }

    func node(forLocationID id: String) -> DiskFileNode? {
        guard let snapshot,
              let location = locations.first(where: { $0.id == id }) else { return nil }
        if location.id == scannedRootPath {
            return snapshot.root
        }
        let path = normalizedPath(location.url.path)
        if path == scannedRootPath {
            return snapshot.root
        }
        return node(in: snapshot, matchingPath: path)
    }

    func analyzedBytes(forLocationID id: String) -> Int64? {
        node(forLocationID: id)?.allocatedBytes ?? analyzedLocationBytes[id]
    }

    func selectNode(_ id: String?) {
        if let id, snapshot?.node(id: id) == nil { return }
        selectedNodeID = id
    }

    func openNode(_ id: String) {
        guard let node = snapshot?.node(id: id) else { return }
        if node.isDirectory, !node.childIDs.isEmpty {
            focusedNodeID = node.id
            selectedNodeID = nil
        } else if node.isDirectory, node.wasSummarized {
            drillIntoSummarizedDirectory(node)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    func activateNodeFromList(_ id: String) {
        let now = Date()
        guard now.timeIntervalSince(lastListActivationAt) > 0.35,
              let node = snapshot?.node(id: id) else { return }
        lastListActivationAt = now

        if node.isDirectory {
            openNode(id)
        } else {
            selectNode(id)
        }
    }

    func focus(_ id: String) {
        guard snapshot?.node(id: id) != nil else { return }
        focusedNodeID = id
        selectedNodeID = nil
    }

    func navigateUp() {
        guard canNavigateUp else { return }
        if let focusedNodeID,
           let parentID = snapshot?.node(id: focusedNodeID)?.parentID {
            focus(parentID)
            return
        }

        guard let previous = scanNavigationHistory.popLast() else { return }
        restoreNavigationEntry(previous)
    }

    private func drillIntoSummarizedDirectory(_ node: DiskFileNode) {
        guard phase != .scanning,
              let currentRootURL = activeScanRootURL ?? snapshot?.root?.url,
              let currentSnapshot = snapshot,
              let currentScannedRootPath = scannedRootPath,
              let currentFocusID = displayedNode?.id ?? snapshot?.rootID else { return }

        scanNavigationHistory.append(
            ScanNavigationEntry(
                rootURL: currentRootURL,
                focusedNodeID: currentFocusID,
                scansVirtualTemporaryLocation: activeScanIsVirtualTemporaryLocation,
                snapshot: currentSnapshot,
                issues: issues,
                scannedRootPath: currentScannedRootPath
            )
        )
        trimNavigationHistoryIfNeeded()
        startScan(
            rootURL: node.url,
            restoreFocusID: nil,
            presentation: .navigation
        )
    }

    private func restoreNavigationEntry(_ entry: ScanNavigationEntry) {
        stopScan(resetToIdle: false)
        snapshot = entry.snapshot
        issues = entry.issues
        scannedRootPath = entry.scannedRootPath
        activeScanRootURL = entry.rootURL
        activeScanIsVirtualTemporaryLocation = entry.scansVirtualTemporaryLocation
        focusedNodeID = entry.snapshot.node(id: entry.focusedNodeID) != nil
            ? entry.focusedNodeID
            : entry.snapshot.rootID
        selectedNodeID = nil
        pendingRestoreFocusID = nil
        progress = nil
        scanPresentation = .navigation
        phase = .finished
        recordAnalyzedLocations(
            in: entry.snapshot,
            scannedRootPath: entry.scannedRootPath
        )
    }

    private func trimNavigationHistoryIfNeeded() {
        while scanNavigationHistory.count > Self.maximumNavigationHistoryDepth {
            // Preserve the original location so Back can always return to the card the user
            // opened. Dropping a middle breadcrumb is preferable to silently rescanning `/`.
            scanNavigationHistory.remove(at: scanNavigationHistory.count > 1 ? 1 : 0)
        }
    }

    func revealInFinder(_ id: String) {
        guard let node = snapshot?.node(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func canMoveNodeToTrash(_ id: String) -> Bool {
        guard phase != .scanning,
              !deletingNodeIDs.contains(id),
              let snapshot,
              id != snapshot.rootID,
              let node = snapshot.node(id: id),
              !node.isSynthetic,
              trashProtectionPath(for: node.url) == nil else {
            return false
        }

        return FileManager.default.fileExists(atPath: node.url.path)
    }

    func requestMoveNodeToTrash(_ id: String, from surface: DiskSpacePresentationSurface) {
        guard canMoveNodeToTrash(id), let node = snapshot?.node(id: id) else { return }
        trashAlertSurface = surface
        trashAlert = .confirmation(
            nodeID: id,
            name: node.name,
            size: node.allocatedBytes,
            path: abbreviatedPath(node.url.path)
        )
    }

    func moveNodeToTrash(_ id: String, from surface: DiskSpacePresentationSurface) {
        guard let snapshot,
              id != snapshot.rootID,
              let node = snapshot.node(id: id),
              !node.isSynthetic else { return }

        if let protectedPath = trashProtectionPath(for: node.url) {
            trashAlertSurface = surface
            trashAlert = .failure(
                id: UUID(),
                message: "\(protectedPath) is a protected macOS location and can’t be moved to Trash."
            )
            return
        }

        guard phase != .scanning, !deletingNodeIDs.contains(id) else { return }

        deletingNodeIDs.insert(id)
        let itemURL = node.url
        let itemName = node.name

        Task { [weak self] in
            let failureMessage = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.trashItem(at: itemURL, resultingItemURL: nil)
                    guard !FileManager.default.fileExists(atPath: itemURL.path) else {
                        return "\(itemName) could not be verified in Trash."
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            deletingNodeIDs.remove(id)

            if let failureMessage {
                trashAlertSurface = surface
                trashAlert = .failure(id: UUID(), message: failureMessage)
                return
            }

            if selectedNodeID == id {
                selectedNodeID = nil
            }

            if let updatedSnapshot = self.snapshot?.removingNode(id: id) {
                self.snapshot = updatedSnapshot
                issues = updatedSnapshot.issues
                reconcileCachedSnapshotsAfterRemovingNode(id)
                if let scannedRootPath {
                    recordAnalyzedLocations(
                        in: updatedSnapshot,
                        scannedRootPath: scannedRootPath
                    )
                }
            } else {
                // A successful Trash action must never launch an unexpected multi-minute scan.
                // This is only an internal snapshot inconsistency; leave refresh under user control.
                phase = .failed(L("The item was moved to Trash, but this view could not update. Choose Rescan to refresh it."))
            }
        }
    }

    func trashAlert(for surface: DiskSpacePresentationSurface) -> DiskSpaceTrashAlert? {
        trashAlertSurface == surface ? trashAlert : nil
    }

    func dismissTrashAlert(from surface: DiskSpacePresentationSurface) {
        guard trashAlertSurface == surface else { return }
        trashAlert = nil
        trashAlertSurface = nil
    }

    private func reconcileCachedSnapshotsAfterRemovingNode(_ id: String) {
        for locationID in Array(cachedLocationScans.keys) {
            guard let cached = cachedLocationScans[locationID],
                  cached.snapshot.node(id: id) != nil,
                  id != cached.snapshot.rootID else { continue }

            guard let updatedSnapshot = cached.snapshot.removingNode(id: id) else {
                cachedLocationScans.removeValue(forKey: locationID)
                cachedLocationOrder.removeAll { $0 == locationID }
                continue
            }
            cachedLocationScans[locationID] = CachedLocationScan(
                snapshot: updatedSnapshot,
                issues: updatedSnapshot.issues,
                scannedRootPath: cached.scannedRootPath,
                rootURL: cached.rootURL,
                scansVirtualTemporaryLocation: cached.scansVirtualTemporaryLocation
            )
        }

        scanNavigationHistory = scanNavigationHistory.map { entry in
            guard entry.snapshot.node(id: id) != nil,
                  id != entry.snapshot.rootID,
                  let updatedSnapshot = entry.snapshot.removingNode(id: id) else { return entry }
            return ScanNavigationEntry(
                rootURL: entry.rootURL,
                focusedNodeID: entry.focusedNodeID,
                scansVirtualTemporaryLocation: entry.scansVirtualTemporaryLocation,
                snapshot: updatedSnapshot,
                issues: updatedSnapshot.issues,
                scannedRootPath: entry.scannedRootPath
            )
        }
    }

    /// Disk Space may inspect the complete startup volume, but direct Trash actions are limited
    /// to the current user's files, known temporary roots, and writable external volumes.
    private func trashProtectionPath(for url: URL) -> String? {
        if let protectedRoot = DiskScanTrashSafety.protectedRootPath(for: url) {
            return protectedRoot
        }

        let fileManager = FileManager.default
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = fileManager.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL.path

        let protectedUserFolderNames = [
            "Desktop", "Documents", "Downloads", "Library",
            "Movies", "Music", "Pictures", "Public"
        ]
        let protectedUserFolderPaths = Set(
            protectedUserFolderNames.map {
                URL(fileURLWithPath: homePath, isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
                    .standardizedFileURL.path
            }
        )
        if protectedUserFolderPaths.contains(candidatePath) {
            return candidatePath
        }

        if Self.path(candidatePath, isInside: homePath) {
            return nil
        }

        let temporaryRoots = [
            fileManager.temporaryDirectory,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
        ]
        .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }

        if temporaryRoots.contains(where: { Self.path(candidatePath, isInside: $0) }) {
            return nil
        }

        let volumeKeys: Set<URLResourceKey> = [.volumeIsInternalKey]
        let externalVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys),
            options: [.skipHiddenVolumes]
        ) ?? []

        for volumeURL in externalVolumes {
            let values = try? volumeURL.resourceValues(forKeys: volumeKeys)
            guard values?.volumeIsInternal == false else { continue }
            let volumePath = volumeURL.resolvingSymlinksInPath().standardizedFileURL.path
            if Self.path(candidatePath, isInside: volumePath) {
                return nil
            }
        }

        return candidatePath
    }

    private static func path(_ candidate: String, isInside root: String) -> Bool {
        candidate != root && candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func scanWorkerLimit(for rootURL: URL) -> Int {
        // A full-volume walk is long-running background work. One worker keeps the Mac usable;
        // focused folder scans may use two workers without monopolizing the CPU.
        normalizedPath(rootURL.path) == "/" ? 1 : 2
    }

    private var locationRootNode: DiskFileNode? {
        guard let snapshot else { return nil }
        if selectedLocation.id == scannedRootPath {
            return snapshot.root
        }
        let selectedPath = normalizedPath(selectedLocation.url.path)
        if selectedPath == scannedRootPath {
            return snapshot.root
        }
        return node(in: snapshot, matchingPath: selectedPath)
    }

    private func preservedDirectoryURLs(for location: DiskSpaceLocation) -> [URL] {
        guard location.kind == .startupDisk else { return [] }

        let regularLocations = locations
            .filter { $0.kind == .favorite && $0.id != Self.temporaryFilesLocationID }
            .map(\.url)
        let temporarySources = TemporaryFilesScanPlan.make()
            .flatMap(\.sources)
            .map(\.url)
        var seenPaths = Set<String>()
        return (regularLocations + temporarySources).filter {
            seenPaths.insert(normalizedPath($0.path)).inserted
        }
    }

    private func recordAnalyzedLocations(
        in snapshot: DiskScanSnapshot,
        scannedRootPath: String
    ) {
        var next = analyzedLocationBytes
        if let root = snapshot.root {
            next[scannedRootPath] = root.allocatedBytes
        }

        if scannedRootPath == "/" {
            for location in locations where location.id != Self.temporaryFilesLocationID {
                if let node = node(in: snapshot, matchingPath: location.url.path) {
                    next[location.id] = node.allocatedBytes
                }
            }

            let temporaryPaths = Set(
                TemporaryFilesScanPlan.make()
                    .flatMap(\.sources)
                    .map { normalizedPath($0.url.path) }
            )
            let temporaryNodes = temporaryPaths.compactMap {
                node(in: snapshot, matchingPath: $0)
            }
            if !temporaryNodes.isEmpty {
                next[Self.temporaryFilesLocationID] = temporaryNodes.reduce(Int64(0)) {
                    $0 + $1.allocatedBytes
                }
            }
        }

        analyzedLocationBytes = next
    }

    private func node(
        in snapshot: DiskScanSnapshot,
        matchingPath path: String
    ) -> DiskFileNode? {
        for candidate in nodePathCandidates(for: path) {
            if let node = snapshot.node(id: candidate) {
                return node
            }
        }
        return nil
    }

    private func nodePathCandidates(for path: String) -> [String] {
        let normalized = normalizedPath(path)
        let dataPrefix = "/System/Volumes/Data"
        var candidates = [normalized]

        let resolved = URL(fileURLWithPath: normalized, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        candidates.append(resolved)

        if normalized == dataPrefix || normalized.hasPrefix(dataPrefix + "/") {
            let visible = String(normalized.dropFirst(dataPrefix.count))
            candidates.append(visible.isEmpty ? "/" : visible)
        } else if normalized != "/" {
            candidates.append(dataPrefix + normalized)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func startupDiskLocation() -> DiskSpaceLocation {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let volumeName = (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? "Macintosh HD"
        return DiskSpaceLocation(
            id: "/",
            name: volumeName,
            url: root,
            icon: "internaldrive.fill",
            kind: .startupDisk,
            subtitle: L("Startup Disk")
        )
    }
}

@MainActor
final class DiskSpaceWindowController: NSObject, NSWindowDelegate {
    private let store: DiskSpaceStore
    private let window: NSWindow

    init(diskMonitor: DiskMonitor, store: DiskSpaceStore) {
        self.store = store
        let rootView = DiskSpaceRootView(store: store, diskMonitor: diskMonitor)
        let hostingController = NSHostingController(rootView: rootView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("ClearDisk — Disk Space")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.contentViewController = hostingController
        window.center()

        super.init()
        window.delegate = self
    }

    func show() {
        store.reloadLocations()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct DiskSpaceRootView: View {
    @ObservedObject var store: DiskSpaceStore
    @ObservedObject var diskMonitor: DiskMonitor
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    private var selection: Binding<String?> {
        Binding(
            get: { store.selectedLocationID },
            set: store.selectLocation
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("This Mac") {
                    ForEach(store.locations.filter { $0.kind != .favorite }) { location in
                        DiskSpaceSidebarRow(location: location)
                            .tag(location.id)
                    }
                }

                Section("Favorites") {
                    ForEach(store.locations.filter { $0.kind == .favorite }) { location in
                        DiskSpaceSidebarRow(location: location)
                            .tag(location.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Locations")
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            DiskSpaceWorkspaceView(store: store, diskMonitor: diskMonitor)
                .navigationTitle("Disk Space")
        }
        .frame(minWidth: 820, minHeight: 560)
        .preferredColorScheme(appearance.colorScheme)
    }
}

enum DiskSpaceCompactPage {
    case locations
    case workspace
}

private struct DiskSpaceNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct DiskSpaceCompactView: View {
    private enum ScanAllStage {
        case diskSpace
        case caches
    }

    @ObservedObject var store: DiskSpaceStore
    @ObservedObject var diskMonitor: DiskMonitor
    let isExpanded: Bool
    @Binding var page: DiskSpaceCompactPage
    let onOpenDiskSpace: () -> Void
    let onOpenCaches: () -> Void

    @AppStorage("diskSpaceTreemapGroupingEnabled") private var groupingEnabled = false
    @AppStorage("diskSpaceTreemapGroupingThresholdMB") private var groupingThresholdMB = 10
    @State private var scanAllStage: ScanAllStage?

    private var isScanAllInProgress: Bool {
        scanAllStage != nil
    }

    private var groupingThresholdBytes: Int64? {
        guard groupingEnabled else { return nil }
        return Int64(max(groupingThresholdMB, 1)) * 1_048_576
    }

    var body: some View {
        Group {
            if page == .locations {
                compactLocations
            } else {
                switch store.phase {
                case .scanning:
                    if store.isLoadingNavigation {
                        compactNavigationLoading
                    } else {
                        compactScanning
                    }
                case .finished where store.hasResultsForSelection:
                    compactResults
                case .failed(let message):
                    compactLocationOverview(errorMessage: message)
                default:
                    compactLocationOverview()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: store.phase) { _, _ in
            finishScanAllIfPossible()
        }
        .onChange(of: diskMonitor.isScanningCaches) { _, _ in
            finishScanAllIfPossible()
        }
        .onChange(of: diskMonitor.isScanning) { _, _ in
            finishScanAllIfPossible()
        }
        .alert(item: diskSpaceTrashAlertBinding(store: store, surface: .compact)) { alert in
            diskSpaceTrashAlert(alert, store: store, surface: .compact)
        }
    }

    private var compactLocations: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage Locations")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Choose where you want to look.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isScanAllInProgress {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Scanning All…")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    }
                    .accessibilityLabel("Scanning all storage locations")
                } else if store.phase == .scanning || diskMonitor.isScanningCaches {
                    Button {
                        if store.phase == .scanning {
                            page = .workspace
                        }
                    } label: {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Scanning")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                } else {
                    Button(action: scanAllLocations) {
                        Label("Scan All", systemImage: "magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Scan this Mac, quick locations, and caches")
                }
            }

            if let startupDisk = store.locations.first(where: { $0.kind == .startupDisk }) {
                DiskSpaceMacLocationCard(
                    location: startupDisk,
                    diskMonitor: diskMonitor,
                    analyzedBytes: store.analyzedBytes(forLocationID: startupDisk.id),
                    isScanning: isScanAllInProgress || (
                        store.phase == .scanning &&
                        store.selectedLocationID == startupDisk.id
                    ),
                    isDisabled: store.phase == .scanning &&
                        store.selectedLocationID != startupDisk.id,
                    action: {
                        store.selectLocation(startupDisk.id)
                        onOpenDiskSpace()
                    }
                )
            }

            let favorites = store.locations.filter { $0.kind == .favorite }
            let home = favorites.first { $0.name == "Home" }
            let orderedFavorites = favorites.filter { $0.id != home?.id } + [home].compactMap { $0 }
            Text("QUICK LOCATIONS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(orderedFavorites) { location in
                    DiskSpaceQuickLocationCard(
                        location: location,
                        analyzedBytes: store.analyzedBytes(forLocationID: location.id),
                        isScanning: isScanAllInProgress || (
                            store.phase == .scanning &&
                            store.selectedLocationID == location.id
                        ),
                        isDisabled: store.phase == .scanning &&
                            store.selectedLocationID != location.id,
                        action: { openLocation(location) }
                    )
                }

                DiskSpaceCachesLocationCard(
                    hasScanned: diskMonitor.hasCompletedCacheScan,
                    isScanning: isScanAllInProgress || diskMonitor.isScanningCaches,
                    totalSize: diskMonitor.devCaches.reduce(Int64(0)) { $0 + $1.size },
                    action: onOpenCaches
                )
            }

            let externalVolumes = store.locations.filter { $0.kind == .externalVolume }
            if !externalVolumes.isEmpty {
                Text("EXTERNAL VOLUMES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                    .padding(.top, 2)

                VStack(spacing: 1) {
                    ForEach(externalVolumes) { location in
                        DiskSpaceExternalLocationRow(
                            location: location,
                            analyzedBytes: store.analyzedBytes(forLocationID: location.id),
                            isDisabled: store.phase == .scanning &&
                                store.selectedLocationID != location.id,
                            action: { openLocation(location) }
                        )
                    }
                }
                .padding(5)
                .background(
                    Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

        }
    }

    private func compactLocationOverview(errorMessage: String? = nil) -> some View {
        VStack(spacing: 12) {
            compactWorkspaceNavigation

            if store.selectedLocation.kind == .startupDisk {
                DiskCapacityCard(diskMonitor: diskMonitor)
            }

            VStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            errorMessage == nil
                                ? Color.accentColor.opacity(0.10)
                                : Color.orange.opacity(0.10)
                        )
                    Image(systemName: errorMessage == nil ? store.selectedLocation.icon : "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(errorMessage == nil ? Color.accentColor : .orange)
                }
                .frame(width: 54, height: 54)

                VStack(spacing: 4) {
                    Text(errorMessage == nil ? store.selectedLocation.name : L("Scan couldn’t finish"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(
                        errorMessage
                            ?? L("Build a visual map of this location, then open folders to see what is using the most space.")
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if errorMessage == nil {
                        store.startScan()
                    } else {
                        store.rescanCurrentRoot()
                    }
                } label: {
                    Label(
                        errorMessage == nil ? "Analyze \(store.selectedLocation.name)" : L("Try Again"),
                        systemImage: "magnifyingglass"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Read-only analysis — scanning never removes files.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    private func openLocation(_ location: DiskSpaceLocation) {
        if store.phase == .scanning {
            page = .workspace
            return
        }

        store.selectLocation(location.id)
        let hasExistingResults = store.phase == .finished &&
            store.node(forLocationID: location.id) != nil
        page = .workspace
        if !hasExistingResults {
            store.startScan()
        }
    }

    private func scanAllLocations() {
        guard store.phase != .scanning,
              !diskMonitor.isScanningCaches,
              !diskMonitor.isScanning else { return }
        guard let startupDisk = store.locations.first(where: { $0.kind == .startupDisk }) else { return }

        // Disk mapping and cache classification both walk large directory trees. Run them in
        // sequence so Scan All never combines their CPU and I/O load into one system-wide spike.
        scanAllStage = .diskSpace

        DispatchQueue.main.async {
            store.selectLocation(startupDisk.id)
            store.startScan()
        }
    }

    private func finishScanAllIfPossible() {
        guard let scanAllStage else { return }

        switch scanAllStage {
        case .diskSpace:
            guard store.phase != .scanning else { return }
            self.scanAllStage = .caches
            diskMonitor.scanCaches()
            // A denied-access path can complete synchronously without publishing a state change.
            DispatchQueue.main.async {
                finishScanAllIfPossible()
            }

        case .caches:
            guard !diskMonitor.isScanningCaches, !diskMonitor.isScanning else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.scanAllStage = nil
            }
        }
    }

    private var compactWorkspaceNavigation: some View {
        HStack(spacing: 6) {
            Button {
                page = .locations
            } label: {
                Label("Locations", systemImage: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(DiskSpaceNavigationButtonStyle())
            .foregroundStyle(Color.accentColor)

            Spacer()
        }
    }

    private var compactScanning: some View {
        VStack(spacing: 12) {
            compactWorkspaceNavigation

            HStack {
                Label("Scanning \(store.selectedLocation.name)", systemImage: "internaldrive.fill.badge.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Stop", role: .cancel) { store.stopScan() }
                    .controlSize(.small)
            }

            DiskSpaceScanVisualizer(compact: true)

            DiskSpaceScanProgressTrack(value: store.progress?.fractionCompleted ?? 0)
                .frame(height: 5)

            if let progress = store.progress {
                HStack(spacing: 8) {
                    Text(scanStageTitle(for: progress))
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 6)
                    Text("\(Int(min(max(progress.fractionCompleted, 0), 0.999) * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                if !progress.currentPath.hasSuffix("…") {
                    Text(abbreviatedPath(progress.currentPath))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text(String(format: L("%@ files"), progress.filesVisited.formatted()))
                    Spacer()
                    Text(String(format: L("%@ folders"), progress.directoriesVisited.formatted()))
                    Spacer()
                    Text(formatBytes(progress.bytesDiscovered))
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(14)
        .background(
            Color.accentColor.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var compactNavigationLoading: some View {
        VStack(spacing: 12) {
            compactWorkspaceNavigation
            DiskSpaceNavigationLoadingView(store: store, compact: true)
        }
        .frame(maxWidth: .infinity, minHeight: isExpanded ? 420 : 300)
    }

    private var compactResults: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    if store.canNavigateUp {
                        store.navigateUp()
                    } else {
                        page = .locations
                    }
                } label: {
                    Label(store.canNavigateUp ? "Back" : "Locations", systemImage: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(DiskSpaceNavigationButtonStyle())
                .foregroundStyle(Color.accentColor)

                Spacer()

                if store.canNavigateUp {
                    Button {
                        page = .locations
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Storage Locations")
                }

                DiskSpaceTreemapOptionsButton(
                    isEnabled: $groupingEnabled,
                    thresholdMB: $groupingThresholdMB
                )

                Button {
                    store.rescanCurrentRoot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Rescan")
            }

            if let node = store.displayedNode {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(abbreviatedPath(node.url.deletingLastPathComponent().path))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formatBytes(node.allocatedBytes))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Text(String(format: L("%@ files"), node.descendantFileCount.formatted()))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DiskSpaceTreemapView(
                nodes: store.displayedChildren,
                selectedNodeID: store.selectedNodeID,
                groupingThresholdBytes: groupingThresholdBytes,
                onSelect: store.selectNode,
                onOpen: store.openNode
            )
            .frame(height: isExpanded ? 360 : 250)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            if let selectedNode = store.selectedNode {
                HStack(spacing: 8) {
                    Image(systemName: selectedNode.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(selectedNode.isDirectory ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedNode.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(formatBytes(selectedNode.allocatedBytes))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedNode.isDirectory,
                       selectedNode.wasSummarized || !selectedNode.childIDs.isEmpty {
                        Button("Open") { store.openNode(selectedNode.id) }
                            .controlSize(.mini)
                    }
                    Button {
                        store.revealInFinder(selectedNode.id)
                    } label: {
                        Image(systemName: "finder")
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")

                    if store.deletingNodeIDs.contains(selectedNode.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 18)
                    } else {
                        Button {
                            store.requestMoveNodeToTrash(selectedNode.id, from: .compact)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .disabled(!store.canMoveNodeToTrash(selectedNode.id))
                        .help("Move to Trash")
                    }
                }
                .padding(9)
                .background(
                    Color.accentColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }

            HStack {
                Text("Contents")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(format: L("%@ items"), store.displayedChildren.count.formatted()))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            LazyVStack(spacing: 1) {
                ForEach(store.displayedChildren) { node in
                    DiskSpaceCompactRow(
                        node: node,
                        isSelected: node.id == store.selectedNodeID,
                        activate: { store.activateNodeFromList(node.id) },
                        open: { store.openNode(node.id) },
                        reveal: { store.revealInFinder(node.id) },
                        canTrash: store.canMoveNodeToTrash(node.id),
                        isDeleting: store.deletingNodeIDs.contains(node.id),
                        trash: { store.requestMoveNodeToTrash(node.id, from: .compact) }
                    )
                }
            }
        }
    }
}

private struct DiskSpaceMacLocationCard: View {
    let location: DiskSpaceLocation
    @ObservedObject var diskMonitor: DiskMonitor
    let analyzedBytes: Int64?
    let isScanning: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var usedFraction: Double {
        guard diskMonitor.totalSpace > 0 else { return 0 }
        return min(max(Double(diskMonitor.usedSpace) / Double(diskMonitor.totalSpace), 0), 1)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.13), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: usedFraction)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((usedFraction * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: location.icon)
                            .foregroundStyle(Color.accentColor)
                        Text(location.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }

                    Text(String(format: L("%@ available"), formatBytes(diskMonitor.freeSpace)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text(
                        isScanning
                            ? L("Scanning startup disk…")
                            : analyzedBytes.map { "\(formatBytes($0)) indexed" }
                                ?? L("Analyze the complete startup disk")
                    )
                        .font(.system(size: 9))
                        .foregroundStyle(
                            isScanning
                                ? Color.accentColor
                                : analyzedBytes == nil
                                ? Color.secondary.opacity(0.72)
                                : Color.accentColor
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                locationActionLabel
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.085)
                    : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var locationActionLabel: some View {
        if isScanning {
            ProgressView()
                .controlSize(.small)
        } else {
            HStack(spacing: 4) {
                Text("Open")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
        }
    }

    private var ringColor: Color {
        if usedFraction >= 0.9 { return .red }
        if usedFraction >= 0.75 { return .orange }
        return .accentColor
    }
}

private struct DiskSpaceCachesLocationCard: View {
    let hasScanned: Bool
    let isScanning: Bool
    let totalSize: Int64
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.11))
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.purple)
                    }
                    .frame(width: 30, height: 30)

                    Spacer()

                    if isScanning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Caches")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundStyle(hasScanned ? .secondary : .tertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 87, alignment: .leading)
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.075)
                    : Color.primary.opacity(0.028),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Review caches")
    }

    private var statusText: String {
        if isScanning { return "Scanning…" }
        if !hasScanned { return L("Not scanned yet") }
        if totalSize == 0 { return "No caches found" }
        return formatBytes(totalSize)
    }
}

private struct DiskSpaceQuickLocationCard: View {
    let location: DiskSpaceLocation
    let analyzedBytes: Int64?
    let isScanning: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.11))
                        Image(systemName: location.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30, height: 30)

                    Spacer()

                    if isScanning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(location.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(
                        isScanning
                            ? "Scanning…"
                            : analyzedBytes.map(formatBytes) ?? L("Not analyzed")
                    )
                        .font(.system(size: 9))
                        .foregroundStyle(
                            isScanning
                                ? Color.accentColor
                                : analyzedBytes == nil ? Color.secondary.opacity(0.55) : Color.secondary
                        )
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 87, alignment: .leading)
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.075)
                    : Color.primary.opacity(0.028),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isScanning ? 0.48 : 1)
        .onHover { isHovered = $0 }
    }
}

private struct DiskSpaceExternalLocationRow: View {
    let location: DiskSpaceLocation
    let analyzedBytes: Int64?
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: location.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name)
                        .font(.system(size: 10, weight: .medium))
                    Text(analyzedBytes.map(formatBytes) ?? location.subtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
    }
}

private struct DiskSpaceCompactRow: View {
    let node: DiskFileNode
    let isSelected: Bool
    let activate: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    let canTrash: Bool
    let isDeleting: Bool
    let trash: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: activate) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(.plain)

            Button(action: activate) {
                HStack(spacing: 7) {
                    Text(node.name)
                        .font(.system(size: 10))
                        .lineLimit(1)

                    Spacer(minLength: 5)

                    Text(formatBytes(node.allocatedBytes))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if node.isDirectory, node.wasSummarized || !node.childIDs.isEmpty {
                Button(action: open) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .help("Open Folder")
            }

            Button(action: reveal) {
                Image(systemName: "finder")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.blue)
                    .frame(width: 20, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")

            if isDeleting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 22)
            } else {
                Button(action: trash) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(canTrash ? Color.red : Color.secondary.opacity(0.45))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!canTrash)
                .help(canTrash ? "Move to Trash" : L("Protected location"))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contextMenu {
            if node.isDirectory, node.wasSummarized || !node.childIDs.isEmpty {
                Button("Open Folder", action: open)
            }
            Button("Show in Finder", action: reveal)
            if canTrash {
                Divider()
                Button("Move to Trash", role: .destructive, action: trash)
            }
        }
    }
}

private struct DiskSpaceSidebarRow: View {
    let location: DiskSpaceLocation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: location.icon)
                .foregroundStyle(location.kind == .startupDisk ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(location.name)
                    .lineLimit(1)
                Text(location.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DiskSpaceWorkspaceView: View {
    @ObservedObject var store: DiskSpaceStore
    @ObservedObject var diskMonitor: DiskMonitor

    var body: some View {
        VStack(spacing: 0) {
            DiskSpaceToolbar(store: store)
            Divider()

            switch store.phase {
            case .scanning:
                if store.isLoadingNavigation {
                    DiskSpaceNavigationLoadingView(store: store, compact: false)
                } else {
                    DiskSpaceScanningView(store: store)
                }
            case .finished where store.hasResultsForSelection:
                DiskSpaceResultsView(store: store)
            case .failed(let message):
                DiskSpaceEmptyView(
                    store: store,
                    diskMonitor: diskMonitor,
                    errorMessage: message
                )
            default:
                DiskSpaceEmptyView(store: store, diskMonitor: diskMonitor)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: diskSpaceTrashAlertBinding(store: store, surface: .window)) { alert in
            diskSpaceTrashAlert(alert, store: store, surface: .window)
        }
    }
}

private struct DiskSpaceToolbar: View {
    @ObservedObject var store: DiskSpaceStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedLocation.name)
                    .font(.headline)
                Text(store.selectedLocationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if store.phase == .scanning {
                Button("Stop", role: .cancel) { store.stopScan() }
            } else {
                Button {
                    if store.phase == .finished {
                        store.rescanCurrentRoot()
                    } else {
                        store.startScan()
                    }
                } label: {
                    Label(store.phase == .finished ? "Rescan" : "Scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }
}

private struct DiskSpaceEmptyView: View {
    @ObservedObject var store: DiskSpaceStore
    @ObservedObject var diskMonitor: DiskMonitor
    var errorMessage: String?

    private var isStartupDisk: Bool {
        store.selectedLocation.kind == .startupDisk
    }

    var body: some View {
        VStack(spacing: 26) {
            DiskCapacityCard(diskMonitor: diskMonitor)
                .frame(maxWidth: 620)

            Spacer(minLength: 0)

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 76, height: 76)
                    Image(systemName: store.selectedLocation.icon)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 7) {
                    Text("See what’s using your storage")
                        .font(.title2.weight(.semibold))
                    Text(String(format: L("Scan %@ to find the folders and files taking the most space."), store.selectedLocation.name))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                }

                Button {
                    if errorMessage == nil {
                        store.startScan()
                    } else {
                        store.rescanCurrentRoot()
                    }
                } label: {
                    Label(
                        isStartupDisk ? L("Scan This Mac") : "Scan \(store.selectedLocation.name)",
                        systemImage: "magnifyingglass"
                    )
                    .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                } else if isStartupDisk {
                    Text("Read-only analysis. ClearDisk won’t remove anything during a scan.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(28)
    }
}

private struct DiskCapacityCard: View {
    @ObservedObject var diskMonitor: DiskMonitor

    private var usedFraction: Double {
        guard diskMonitor.totalSpace > 0 else { return 0 }
        return min(max(Double(diskMonitor.usedSpace) / Double(diskMonitor.totalSpace), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Storage")
                        .font(.headline)
                    Text("Current APFS capacity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: L("%@ free"), formatBytes(diskMonitor.freeSpace)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(capacityColor)
                        .frame(width: geometry.size.width * usedFraction)
                }
            }
            .frame(height: 10)

            HStack {
                Text(String(format: L("%@ used"), formatBytes(diskMonitor.usedSpace)))
                Spacer()
                Text(String(format: L("%@ total"), formatBytes(diskMonitor.totalSpace)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var capacityColor: Color {
        if usedFraction >= 0.9 { return .red }
        if usedFraction >= 0.75 { return .orange }
        return .accentColor
    }
}

private struct DiskSpaceScanVisualizer: View {
    let compact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion ? 0.52 : elapsed.truncatingRemainder(dividingBy: 2.8) / 2.8
                let pulse = reduceMotion ? 0.5 : (sin(elapsed * 2.4) + 1) / 2
                let sweepWidth = max(proxy.size.width * 0.24, 58)

                ZStack {
                    RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.035),
                                    Color.primary.opacity(0.018),
                                    Color.accentColor.opacity(0.07)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Ellipse()
                        .stroke(Color.accentColor.opacity(0.11 + pulse * 0.07), lineWidth: 1)
                        .frame(width: compact ? 102 : 156, height: compact ? 34 : 52)
                        .scaleEffect(0.92 + pulse * 0.09)

                    Ellipse()
                        .stroke(Color.accentColor.opacity(0.08), lineWidth: 0.75)
                        .frame(width: compact ? 142 : 220, height: compact ? 48 : 72)
                        .scaleEffect(0.96 + pulse * 0.05)

                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: compact ? 24 : 36, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .shadow(color: Color.accentColor.opacity(0.28), radius: compact ? 7 : 12)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.08),
                                    Color.accentColor.opacity(0.48),
                                    Color.white.opacity(0.22),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: sweepWidth)
                        .blur(radius: compact ? 3 : 5)
                        .offset(x: -proxy.size.width / 2 - sweepWidth + phase * (proxy.size.width + sweepWidth * 2))
                        .blendMode(.screen)
                        .mask(
                            RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                        )

                    RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
                .drawingGroup(opaque: false, colorMode: .linear)
            }
        }
        .frame(height: compact ? 70 : 122)
        .accessibilityHidden(true)
    }
}

private struct DiskSpaceScanProgressTrack: View {
    let value: Double

    private var clampedValue: Double {
        min(max(value, 0.012), 0.998)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.72), Color.accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(proxy.size.width * clampedValue, proxy.size.height))
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 3)
            }
        }
        .animation(.smooth(duration: 0.35), value: clampedValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int(clampedValue * 100)) percent")
    }
}

private struct DiskSpaceScanningView: View {
    @ObservedObject var store: DiskSpaceStore

    private var progressValue: Double {
        min(max(store.progress?.fractionCompleted ?? 0, 0), 1)
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            DiskSpaceScanVisualizer(compact: false)
                .frame(maxWidth: 430)

            VStack(spacing: 6) {
                Text(String(format: L("Scanning %@"), store.selectedLocation.name))
                    .font(.title2.weight(.semibold))
                Text("Larger disks can take a while. You can keep using your Mac.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 7) {
                HStack {
                    Text(store.progress.map(scanStageTitle(for:)) ?? L("Starting scan…"))
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int(min(progressValue, 0.999) * 100))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                DiskSpaceScanProgressTrack(value: progressValue)
                    .frame(height: 6)
            }
            .frame(width: 360)

            if let progress = store.progress {
                VStack(spacing: 8) {
                    if !progress.currentPath.hasSuffix("…") {
                        Text(abbreviatedPath(progress.currentPath))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 520)
                    }

                    Text("\(progress.filesVisited.formatted()) files  ·  \(progress.directoriesVisited.formatted()) folders  ·  \(formatBytes(progress.bytesDiscovered)) found")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button("Stop Scan", role: .cancel) { store.stopScan() }
                .controlSize(.large)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiskSpaceNavigationLoadingView: View {
    @ObservedObject var store: DiskSpaceStore
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            Spacer()

            ProgressView()
                .controlSize(compact ? .regular : .large)

            VStack(spacing: compact ? 3 : 5) {
                Text(String(format: L("Opening %@"), store.navigationLoadingTitle))
                    .font(compact ? .system(size: 13, weight: .semibold) : .headline)
                    .lineLimit(1)
                Text("Loading folder contents…")
                    .font(compact ? .system(size: 10) : .subheadline)
                    .foregroundStyle(.secondary)
                if let path = store.navigationLoadingPath {
                    Text(path)
                        .font(compact ? .system(size: 9, design: .monospaced) : .caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: compact ? 330 : 480)
                        .padding(.top, compact ? 1 : 2)
                }
            }

            Spacer()
        }
        .padding(compact ? 20 : 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening \(store.navigationLoadingTitle)")
    }
}

private struct DiskSpaceResultsView: View {
    @ObservedObject var store: DiskSpaceStore
    @AppStorage("diskSpaceTreemapGroupingEnabled") private var groupingEnabled = false
    @AppStorage("diskSpaceTreemapGroupingThresholdMB") private var groupingThresholdMB = 10

    private var groupingThresholdBytes: Int64? {
        guard groupingEnabled else { return nil }
        return Int64(max(groupingThresholdMB, 1)) * 1_048_576
    }

    var body: some View {
        VStack(spacing: 0) {
            if let node = store.displayedNode {
                DiskSpaceWorkspaceHeader(store: store, node: node)

                Divider()

                VSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Disk Map")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let selectedNode = store.selectedNode {
                                Text("\(selectedNode.name) · \(formatBytes(selectedNode.allocatedBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("Double-click a folder to open it")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            DiskSpaceTreemapOptionsButton(
                                isEnabled: $groupingEnabled,
                                thresholdMB: $groupingThresholdMB
                            )
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 36)

                        Divider()

                        DiskSpaceTreemapView(
                            nodes: store.displayedChildren,
                            selectedNodeID: store.selectedNodeID,
                            groupingThresholdBytes: groupingThresholdBytes,
                            onSelect: store.selectNode,
                            onOpen: store.openNode
                        )
                    }
                    .frame(minHeight: 235)

                    DiskSpaceFileTable(store: store)
                        .frame(minHeight: 190)
                }
            }
        }
    }
}

private struct DiskSpaceTreemapOptionsButton: View {
    @Binding var isEnabled: Bool
    @Binding var thresholdMB: Int
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isEnabled ? "eye.fill" : "eye")
                if isEnabled {
                    Text(String(format: L("< %d MB"), thresholdMB))
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .padding(.horizontal, isEnabled ? 8 : 6)
            .frame(height: 24)
            .background(
                isEnabled ? Color.accentColor.opacity(0.10) : Color.clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Treemap Display Options")
        .accessibilityLabel("Treemap Display Options")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Treemap Display")
                        .font(.headline)
                    Text("Every item is shown unless you enable grouping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Group smaller items", isOn: $isEnabled)

                if isEnabled {
                    HStack(spacing: 8) {
                        Text("Group items smaller than")
                        TextField(
                            "10",
                            value: thresholdBinding,
                            format: .number.grouping(.never)
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        Text("MB")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Text("Items below this size appear as one group in the map. They remain individually visible in the table.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack {
                    Text("Saved automatically")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if isEnabled {
                        Button("Show Every Item") {
                            isEnabled = false
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { thresholdMB },
            set: { thresholdMB = min(max($0, 1), 1_000_000) }
        )
    }
}

private struct DiskSpaceWorkspaceHeader: View {
    @ObservedObject var store: DiskSpaceStore
    let node: DiskFileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.title2.weight(.semibold))
                    Text(abbreviatedPath(node.url.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let finishedAt = store.snapshot?.finishedAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last Updated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(finishedAt, style: .time)
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            HStack(spacing: 14) {
                DiskSpaceBreadcrumb(store: store)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 18) {
                    DiskSpaceMetric(title: "Scanned", value: formatBytes(node.allocatedBytes))
                    DiskSpaceMetric(title: "Files", value: node.descendantFileCount.formatted())
                    DiskSpaceMetric(title: "Items", value: store.displayedChildren.count.formatted())
                    DiskSpaceMetric(
                        title: "Warnings",
                        value: store.issues.count.formatted(),
                        warning: !store.issues.isEmpty
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct DiskSpaceBreadcrumb: View {
    @ObservedObject var store: DiskSpaceStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.navigateUp()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 28)
                    .background(
                        Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!store.canNavigateUp)
            .help("Up One Level")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.breadcrumbNodes) { breadcrumbNode in
                        Button {
                            store.focus(breadcrumbNode.id)
                        } label: {
                            Text(breadcrumbNode.name)
                                .font(.caption.weight(
                                    breadcrumbNode.id == store.displayedNode?.id
                                        ? .semibold
                                        : .regular
                                ))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            breadcrumbNode.id == store.displayedNode?.id
                                ? Color.primary
                                : Color.secondary
                        )

                        if breadcrumbNode.id != store.displayedNode?.id {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

private struct DiskSpaceFileTable: View {
    @ObservedObject var store: DiskSpaceStore

    private var selection: Binding<Set<String>> {
        Binding(
            get: { store.selectedNodeID.map { [$0] } ?? [] },
            set: { store.selectNode($0.first) }
        )
    }

    var body: some View {
        Table(store.displayedChildren, selection: selection) {
            TableColumn("Name") { node in
                Button {
                    store.activateNodeFromList(node.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                            .frame(width: 18)

                        Text(node.name)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.isDirectory ? "Open Folder" : L("Select File"))
            }
            .width(min: 240, ideal: 360)

            TableColumn("Allocated") { node in
                Text(formatBytes(node.allocatedBytes))
                    .monospacedDigit()
            }
            .width(min: 95, ideal: 115)

            TableColumn("Kind") { node in
                Text(node.isPackage ? "Package" : node.isDirectory ? "Folder" : "File")
            }
            .width(min: 75, ideal: 90)

            TableColumn("Files") { node in
                Text(node.descendantFileCount.formatted())
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 72)

            TableColumn("Modified") { node in
                if let modified = node.lastModified {
                    Text(modified, style: .date)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 105, ideal: 130)

            TableColumn("") { node in
                HStack(spacing: 10) {
                    Button {
                        store.revealInFinder(node.id)
                    } label: {
                        Image(systemName: "finder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blue)
                    .help("Reveal in Finder")

                    if store.deletingNodeIDs.contains(node.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16)
                    } else {
                        Button {
                            store.requestMoveNodeToTrash(node.id, from: .window)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            store.canMoveNodeToTrash(node.id)
                                ? Color.red
                                : Color.secondary.opacity(0.4)
                        )
                        .disabled(!store.canMoveNodeToTrash(node.id))
                        .help(
                            store.canMoveNodeToTrash(node.id)
                                ? "Move to Trash"
                                : L("Protected location")
                        )
                    }
                }
            }
            .width(min: 58, ideal: 64, max: 70)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let nodeID = selectedIDs.first,
               let node = store.snapshot?.node(id: nodeID) {
                if node.isDirectory, node.wasSummarized || !node.childIDs.isEmpty {
                    Button("Open Folder") { store.openNode(nodeID) }
                }
                Button("Show in Finder") { store.revealInFinder(nodeID) }
                if store.canMoveNodeToTrash(nodeID) {
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        store.requestMoveNodeToTrash(nodeID, from: .window)
                    }
                }
            }
        }
    }
}

private struct DiskSpaceMetric: View {
    let title: String
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(warning ? Color.orange : .primary)
        }
        .frame(minWidth: 66, alignment: .leading)
    }
}

@MainActor
private func diskSpaceTrashAlertBinding(
    store: DiskSpaceStore,
    surface: DiskSpacePresentationSurface
) -> Binding<DiskSpaceTrashAlert?> {
    Binding(
        get: { store.trashAlert(for: surface) },
        set: { alert in
            if alert == nil {
                store.dismissTrashAlert(from: surface)
            }
        }
    )
}

@MainActor
private func diskSpaceTrashAlert(
    _ alert: DiskSpaceTrashAlert,
    store: DiskSpaceStore,
    surface: DiskSpacePresentationSurface
) -> Alert {
    switch alert {
    case .confirmation(let nodeID, let name, let size, let path):
        return Alert(
            title: Text(String(format: L("Move “%@” to Trash?"), name)),
            message: Text(
                "This item will be moved to the macOS Trash.\n\nSize: \(formatBytes(size))\nLocation: \(path)\n\nYou can recover it until Trash is emptied."
            ),
            primaryButton: .cancel(Text("Cancel")),
            secondaryButton: .destructive(Text("Move to Trash")) {
                store.moveNodeToTrash(nodeID, from: surface)
            }
        )
    case .failure(_, let message):
        return Alert(
            title: Text("Couldn’t Move to Trash"),
            message: Text(message),
            dismissButton: .default(Text("OK"))
        )
    }
}

private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func scanStageTitle(for progress: DiskScanProgress) -> String {
    switch progress.currentPath {
    case L("Summarizing results…"):
        return L("Summarizing files…")
    case L("Preparing visualization…"):
        return L("Preparing disk map…")
    case L("Building disk map…"):
        return L("Building disk map…")
    default:
        return progress.visitedItemCount == 0 ? L("Starting scan…") : L("Scanning files…")
    }
}

private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
