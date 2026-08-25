import AppKit
import DiskScannerCore
import SwiftUI

private struct DiskSpaceLocation: Identifiable, Hashable {
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

@MainActor
private final class DiskSpaceStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: DiskScanProgress?
    @Published private(set) var snapshot: DiskScanSnapshot?
    @Published private(set) var issues: [DiskScanIssue] = []
    @Published private(set) var locations: [DiskSpaceLocation] = []
    @Published var selectedLocationID = "/"
    @Published private(set) var focusedNodeID: String?
    @Published private(set) var selectedNodeID: String?

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var scannedRootPath: String?
    private var nodeIDByPath: [String: String] = [:]
    private var parentIDByNodeID: [String: String] = [:]

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
        locationRootNode != nil && phase == .finished
    }

    var selectedNode: DiskFileNode? {
        guard let selectedNodeID else { return nil }
        return snapshot?.node(id: selectedNodeID)
    }

    var breadcrumbNodes: [DiskFileNode] {
        guard let snapshot, let displayedNode, let locationRootNode else { return [] }

        var result = [displayedNode]
        var currentID = displayedNode.id
        while currentID != locationRootNode.id,
              let parentID = parentIDByNodeID[currentID],
              let parent = snapshot.node(id: parentID) {
            result.append(parent)
            currentID = parentID
        }
        return result.reversed()
    }

    var canNavigateUp: Bool {
        guard let displayedNode, let locationRootNode else { return false }
        return displayedNode.id != locationRootNode.id
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
                    subtitle: "External Volume"
                )
            )
        }

        let favoriteDefinitions: [(String, URL, String)] = [
            ("Home", home, "house.fill"),
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true), "menubar.dock.rectangle"),
            ("Documents", home.appendingPathComponent("Documents", isDirectory: true), "doc.fill"),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true), "arrow.down.circle.fill"),
            ("Applications", URL(fileURLWithPath: "/Applications", isDirectory: true), "app.fill"),
            ("Library", home.appendingPathComponent("Library", isDirectory: true), "books.vertical.fill")
        ]

        values.append(contentsOf: favoriteDefinitions.compactMap { name, url, icon in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return DiskSpaceLocation(
                id: normalizedPath(url.path),
                name: name,
                url: url,
                icon: icon,
                kind: .favorite,
                subtitle: abbreviatedPath(url.path)
            )
        })

        locations = values
        if !values.contains(where: { $0.id == selectedLocationID }) {
            selectedLocationID = "/"
        }
    }

    func startScan() {
        stopScan(resetToIdle: false)

        let location = selectedLocation
        phase = .scanning
        progress = nil
        issues = []
        focusedNodeID = nil
        selectedNodeID = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = DiskScanRequest(
                    rootURL: location.url,
                    includesHiddenItems: true,
                    expandsPackages: false
                )

                for try await event in scanner.events(for: request) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .progress(let nextProgress):
                        progress = nextProgress
                    case .issue(let issue):
                        issues.append(issue)
                    case .completed(let completedSnapshot):
                        snapshot = completedSnapshot
                        issues = completedSnapshot.issues
                        scannedRootPath = normalizedPath(location.url.path)
                        nodeIDByPath = completedSnapshot.nodesByID.values.reduce(into: [:]) {
                            index, node in
                            // Synthetic/hard-linked records can resolve to the same filesystem
                            // path. Keeping the first avoids turning a valid scan into a crash.
                            let path = normalizedPath(node.url.path)
                            if index[path] == nil { index[path] = node.id }
                        }
                        parentIDByNodeID = completedSnapshot.nodesByID.values.reduce(into: [:]) {
                            parents, node in
                            for childID in node.childIDs where parents[childID] == nil {
                                parents[childID] = node.id
                            }
                        }
                        focusedNodeID = completedSnapshot.rootID
                        selectedNodeID = nil
                        phase = .finished
                    }
                }
            } catch is CancellationError {
                if phase == .scanning { phase = .idle }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stopScan(resetToIdle: Bool = true) {
        scanTask?.cancel()
        scanTask = nil
        if resetToIdle && phase == .scanning {
            phase = .idle
        }
    }

    func selectLocation(_ id: String?) {
        guard let id, id != selectedLocationID else { return }
        selectedLocationID = id
        focusedNodeID = nodeIDByPath[normalizedPath(selectedLocation.url.path)]
        selectedNodeID = nil
        if case .failed = phase { phase = .idle }
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
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    func focus(_ id: String) {
        guard snapshot?.node(id: id) != nil else { return }
        focusedNodeID = id
        selectedNodeID = nil
    }

    func navigateUp() {
        guard canNavigateUp,
              let focusedNodeID,
              let parentID = parentIDByNodeID[focusedNodeID] else { return }
        focus(parentID)
    }

    func revealInFinder(_ id: String) {
        guard let node = snapshot?.node(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private var locationRootNode: DiskFileNode? {
        guard let snapshot else { return nil }
        let selectedPath = normalizedPath(selectedLocation.url.path)
        if selectedPath == scannedRootPath {
            return snapshot.root
        }
        guard let nodeID = nodeIDByPath[selectedPath] else { return nil }
        return snapshot.node(id: nodeID)
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
            subtitle: "Startup Disk"
        )
    }
}

@MainActor
final class DiskSpaceWindowController: NSObject, NSWindowDelegate {
    private let store = DiskSpaceStore()
    private let window: NSWindow

    init(diskMonitor: DiskMonitor) {
        let rootView = DiskSpaceRootView(store: store, diskMonitor: diskMonitor)
        let hostingController = NSHostingController(rootView: rootView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ClearDisk — Disk Space"
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
                DiskSpaceScanningView(store: store)
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
    }
}

private struct DiskSpaceToolbar: View {
    @ObservedObject var store: DiskSpaceStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedLocation.name)
                    .font(.headline)
                Text(store.selectedLocation.url.path)
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
                    store.startScan()
                } label: {
                    Label(store.hasResultsForSelection ? "Rescan" : "Scan", systemImage: "arrow.clockwise")
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
                    Text("Scan \(store.selectedLocation.name) to find the folders and files taking the most space.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                }

                Button {
                    store.startScan()
                } label: {
                    Label(
                        isStartupDisk ? "Scan This Mac" : "Scan \(store.selectedLocation.name)",
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
                Text("\(formatBytes(diskMonitor.freeSpace)) free")
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
                Text("\(formatBytes(diskMonitor.usedSpace)) used")
                Spacer()
                Text("\(formatBytes(diskMonitor.totalSpace)) total")
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

private struct DiskSpaceScanningView: View {
    @ObservedObject var store: DiskSpaceStore

    private var progressValue: Double {
        min(max(store.progress?.fractionCompleted ?? 0, 0), 1)
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "internaldrive.fill.badge.magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("Scanning \(store.selectedLocation.name)")
                    .font(.title2.weight(.semibold))
                Text("Larger disks can take a while. You can keep using your Mac.")
                    .foregroundStyle(.secondary)
            }

            Group {
                if progressValue > 0 {
                    ProgressView(value: progressValue)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 320)

            if let progress = store.progress {
                VStack(spacing: 8) {
                    Text(abbreviatedPath(progress.currentPath))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520)

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

private struct DiskSpaceResultsView: View {
    @ObservedObject var store: DiskSpaceStore

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
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 36)

                        Divider()

                        DiskSpaceTreemapView(
                            nodes: store.displayedChildren,
                            selectedNodeID: store.selectedNodeID,
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
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
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
                HStack(spacing: 8) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 18)
                    Text(node.name)
                        .lineLimit(1)
                }
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
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let nodeID = selectedIDs.first,
               let node = store.snapshot?.node(id: nodeID) {
                if node.isDirectory, !node.childIDs.isEmpty {
                    Button("Open Folder") { store.openNode(nodeID) }
                }
                Button("Show in Finder") { store.revealInFinder(nodeID) }
            }
        } primaryAction: { selectedIDs in
            if let nodeID = selectedIDs.first {
                store.openNode(nodeID)
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

private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
