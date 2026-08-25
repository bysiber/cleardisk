import SwiftUI
import Charts
import ServiceManagement

// MARK: - Layout Constants
enum Layout {
    static let popoverWidth: CGFloat = 380
    static let contentWidth: CGFloat = popoverWidth
    static let popoverHeight: CGFloat = 700
}

// MARK: - Project sheet routing
// Single source of truth for the project screen's sheets. Using one `.sheet(item:)` instead of
// several stacked `.sheet(isPresented:)` modifiers avoids the SwiftUI bug where only one presents.
private enum ActiveProjectSheet: Int, Identifiable {
    case history
    case cleanConfirm
    var id: Int { rawValue }
}

// MARK: - Main View
struct MainView: View {
    @ObservedObject var diskMonitor: DiskMonitor
    @ObservedObject var diskSpaceStore: DiskSpaceStore
    @State private var selectedTab: Tab = .developer
    @State private var showCleanConfirm = false
    @State private var showCleanSafeConfirm = false
    @State private var activeProjectSheet: ActiveProjectSheet?
    @State private var cacheToClean: DevCache?
    @State private var artifactToClean: ProjectArtifact?
    @State private var projectSortMode: ProjectSortMode = .size
    @State private var activeScreen: ActiveScreen = .main
    @State private var cacheCleanMode: CacheCleanMode = .safe
    @State private var selectedArtifactIDs: Set<UUID> = []
    @State private var selectedCacheIDs: Set<UUID> = []
    @State private var showCleanSelectedCachesConfirm = false
    @State private var showRiskyBulkConfirm = false
    @State private var pendingBulkCaches: [DevCache] = []
    @State private var acknowledgesDataLossRisk = false
    @State private var showEmptyTrashConfirm = false
    @State private var showClearHistoryConfirm = false
    @State private var projectFilterMode: ProjectFilterMode = .all
    @State private var isCleaning = false
    @State private var isExpanded = false
    @State private var expandedGroups: Set<String> = []
    @State private var compactDiskSpacePage: DiskSpaceCompactPage = .locations
    @State private var fileToDelete: LargeFile?
    @State private var showDeleteFileConfirm = false
    @State private var expandedLargeFileFolder: String? = nil
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("primaryMode") private var primaryMode: PrimaryMode = .cleaner
    
    enum Tab: String, CaseIterable {
        case diskSpace = "Disk Space"
        case developer = "Developer"
        case projects = "Projects"
        case overview = "Overview"
        case largeFiles = "Large Files"
    }
    
    enum ProjectSortMode: String, CaseIterable {
        case size = "Size"
        case date = "Date"
        case name = "Name"
    }
    
    enum ActiveScreen {
        case main
        case cleanCaches
        case cleanProjects
        case settings
    }
    
    enum CacheCleanMode {
        case safe
        case moderate
        case everything
    }
    
    enum ProjectFilterMode: String, CaseIterable {
        case all = "All"
        case stale = "Stale (>30d)"
    }
    
    var body: some View {
        let content = Group {
            if activeScreen != .main {
                switch activeScreen {
                case .cleanCaches:
                    cleanCachesScreen
                case .cleanProjects:
                    cleanProjectsScreen
                case .settings:
                    settingsScreen
                case .main:
                    EmptyView()
                }
            } else {
                switch primaryMode {
                case .cleaner:
                    mainScreen
                case .review:
                    reviewScreen
                case .diskSpace:
                    diskSpaceScreen
                }
            }
        }
        .frame(width: Layout.contentWidth, height: Layout.popoverHeight)

        let base = content
        .frame(width: Layout.popoverWidth, height: Layout.popoverHeight)
        .overlay {
            ZStack {
                if let sheet = activeProjectSheet {
                    projectSheetOverlay(sheet)
                }
                if showRiskyBulkConfirm {
                    riskyBulkConfirmationOverlay
                }
            }
        }
        // A popover that vanishes out from under a presentation leaves SwiftUI's state stranded,
        // and the UI comes back unclickable. Whatever was open dies with the popover.
        .onReceive(NotificationCenter.default.publisher(for: .clearDiskPopoverDidClose)) { _ in
            dismissAllPresentations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearDiskPrimaryModeRequested)) { notification in
            guard
                let rawValue = notification.object as? String,
                let mode = PrimaryMode(rawValue: rawValue)
            else { return }
            // AppDelegate routes Disk Space to its own resizable workspace window.
            guard mode != .diskSpace else { return }
            switchPrimaryMode(to: mode)
        }

        let cacheAlerts = base
        .alert("Clear History?", isPresented: $showClearHistoryConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                diskMonitor.clearProjectCleanHistory()
            }
        } message: {
            Text("This only removes the local history log. It does NOT restore any previously cleaned caches.")
        }
        .alert("Clean Cache", isPresented: $showCleanConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                if let cache = cacheToClean {
                    isCleaning = true
                    diskMonitor.devCaches.removeAll { $0.id == cache.id }
                    diskMonitor.cleanDevCache(cache)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCleaning = false }
                }
            }
        } message: {
            if let cache = cacheToClean {
                let xcodeWarning = (cache.name.hasPrefix("Xcode") || cache.name == "Swift PM Cache") && diskMonitor.isXcodeRunning()
                    ? "\n\n⚠️ Xcode is currently running! Close Xcode first for best results."
                    : ""
                Text("Delete all contents of \(cache.name)?\nThis will move \(formatBytes(cache.size)) to Trash.\n\n\(cache.riskEmoji) \(cache.riskDescription)\(xcodeWarning)")
            }
        }
        .alert("Clean Safe Caches", isPresented: $showCleanSafeConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                isCleaning = true
                let safeCaches = diskMonitor.devCaches.filter(DiskMonitor.isEligibleForSafeBulkClean)
                let safeIDs = Set(safeCaches.map(\.id))
                diskMonitor.devCaches.removeAll { safeIDs.contains($0.id) }
                diskMonitor.cleanSelectedCaches(safeCaches)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCleaning = false }
            }
        } message: {
            let safeCaches = diskMonitor.devCaches.filter { $0.riskLevel == "safe" }
            let safeTotal = safeCaches.reduce(Int64(0)) { $0 + $1.size }
            let xcodeWarning = diskMonitor.isXcodeRunning()
                ? "\n\n⚠️ Xcode is currently running! Close Xcode first for best results."
                : ""
            Text("Clean \(safeCaches.count) safe caches?\nThis will move \(formatBytes(safeTotal)) to Trash.\n\n🟡 Caution and 🔴 risky caches are NOT included — select those individually.\nFiles go to Trash — you can recover them.\(xcodeWarning)")
        }

        let cleanupAlerts = cacheAlerts
        .alert("Clean Selected Caches", isPresented: $showCleanSelectedCachesConfirm) {
            Button("Cancel", role: .cancel) { pendingBulkCaches = [] }
            Button("Move to Trash", role: .destructive) {
                performBulkClean(pendingBulkCaches)
            }
        } message: {
            let totalSize = pendingBulkCaches.reduce(Int64(0)) { $0 + $1.size }
            let xcodeWarning = diskMonitor.isXcodeRunning()
                ? "\n\n⚠️ Xcode is currently running! Close Xcode first for best results."
                : ""
            Text("Clean \(pendingBulkCaches.count) selected cache(s)?\nThis will move \(formatBytes(totalSize)) to Trash. Disk space is reclaimed only after Trash is emptied.\(xcodeWarning)")
        }
        .alert("Permanently Empty Trash?", isPresented: $showEmptyTrashConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Permanently", role: .destructive) {
                diskMonitor.emptyTrash()
            }
        } message: {
            Text("This permanently deletes all \(formatBytes(diskMonitor.trashSizeBytes)) in your Mac's Trash — including items not moved there by ClearDisk. This cannot be undone.")
        }

        return cleanupAlerts
        .alert("Delete File", isPresented: $showDeleteFileConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                if let file = fileToDelete {
                    diskMonitor.largeFiles.removeAll { $0.id == file.id }
                    diskMonitor.deleteLargeFile(file)
                }
            }
        } message: {
            if let file = fileToDelete {
                Text("Move \"\(file.name)\" to Trash?\n\nSize: \(formatBytes(file.size))\nPath: \(file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))\n\nYou can recover it from Trash.")
            }
        }
        // A clean that frees nothing must say so. Previously the failure was only printed to
        // stdout, so the app showed a success while the files were still on disk.
        .alert(
            "Couldn't Move to Trash",
            isPresented: Binding(
                get: { diskMonitor.cleanFailure != nil },
                set: { if !$0 { diskMonitor.cleanFailure = nil } }
            ),
            presenting: diskMonitor.cleanFailure
        ) { failure in
            if failure.isPermission {
                Button("Open Privacy Settings") { diskMonitor.openFullDiskAccessSettings() }
            }
            Button("OK", role: .cancel) { }
        } message: { failure in
            Text(failure.isPermission
                 ? "\(failure.title) is still on disk — nothing was deleted.\n\n\(failure.reason)\n\nClearDisk needs Full Disk Access to move files to the Trash. Grant it in System Settings → Privacy & Security → Full Disk Access, then quit and reopen ClearDisk."
                 : "\(failure.title) is still on disk — nothing was deleted.\n\n\(failure.reason)")
        }
    }
    
    /// The project sheets are drawn INSIDE the popover instead of with `.sheet`.
    /// A real sheet detaches an AppKit window from the popover; the `.transient` popover then closes
    /// the moment focus moves elsewhere (e.g. the user switches to Finder) while SwiftUI still
    /// believes the sheet is up — it returns as an invisible layer that swallows every click.
    /// An overlay lives in the popover's own view tree, so there is nothing to strand.
    @ViewBuilder
    private func projectSheetOverlay(_ sheet: ActiveProjectSheet) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .onTapGesture { activeProjectSheet = nil }

            Group {
                switch sheet {
                case .history:
                    ProjectCleanHistorySheet(
                        entries: diskMonitor.projectCleanHistory,
                        onClose: { activeProjectSheet = nil },
                        onClearAll: { showClearHistoryConfirm = true }
                    )
                case .cleanConfirm:
                    CleanCacheConfirmSheet(
                        artifact: artifactToClean,
                        onCancel: { activeProjectSheet = nil },
                        onConfirm: {
                            if let artifact = artifactToClean {
                                isCleaning = true
                                diskMonitor.projectArtifacts.removeAll { $0.id == artifact.id }
                                diskMonitor.cleanProjectArtifact(artifact)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCleaning = false }
                            }
                            activeProjectSheet = nil
                        }
                    )
                }
            }
            // A sheet window used to give these views their size and background. Inside the popover
            // they are a card: never wider than the popover, never taller than it, and drawing the
            // material a window would have drawn for them.
            .frame(width: Layout.contentWidth - 28)
            .frame(maxHeight: Layout.popoverHeight - 72)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        }
        .frame(width: Layout.contentWidth, height: Layout.popoverHeight)
    }

    private var riskyBulkConfirmationOverlay: some View {
        let riskyCaches = pendingBulkCaches.filter { $0.riskLevel == "risky" }
        let totalSize = pendingBulkCaches.reduce(Int64(0)) { $0 + $1.size }

        return ZStack {
            Color.black.opacity(0.55)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Risk of Data Loss")
                        .font(.system(size: 15, weight: .bold))
                }

                Text("The red items below may contain sessions, workspace state, containers, volumes, or other data that cannot be rebuilt.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(riskyCaches) { cache in
                            HStack(spacing: 6) {
                                Circle().fill(Color.red).frame(width: 7, height: 7)
                                Text(cache.name)
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(formatBytes(cache.size))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)

                Toggle(isOn: $acknowledgesDataLossRisk) {
                    Text("I understand these items may contain irreplaceable data, and I accept the risk of data loss.")
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)

                Text("\(pendingBulkCaches.count) items · \(formatBytes(totalSize)) will be moved to Trash. Space is not reclaimed until Trash is emptied.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                HStack {
                    Button("Cancel") {
                        cancelRiskyBulkConfirmation()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Move to Trash", role: .destructive) {
                        let caches = pendingBulkCaches
                        cancelRiskyBulkConfirmation(clearPending: false)
                        performBulkClean(caches)
                    }
                    .disabled(!acknowledgesDataLossRisk)
                }
            }
            .padding(16)
            .frame(width: Layout.contentWidth - 32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        .frame(width: Layout.contentWidth, height: Layout.popoverHeight)
    }

    private func requestBulkClean(_ caches: [DevCache]) {
        guard !caches.isEmpty else { return }
        pendingBulkCaches = caches
        if DiskMonitor.requiresDataLossAcknowledgement(for: caches) {
            acknowledgesDataLossRisk = false
            showRiskyBulkConfirm = true
        } else {
            showCleanSelectedCachesConfirm = true
        }
    }

    private func performBulkClean(_ caches: [DevCache]) {
        guard !caches.isEmpty else { return }
        let ids = Set(caches.map(\.id))
        isCleaning = true
        diskMonitor.devCaches.removeAll { ids.contains($0.id) }
        diskMonitor.cleanSelectedCaches(caches)
        selectedCacheIDs = []
        pendingBulkCaches = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCleaning = false
            activeScreen = .main
        }
    }

    private func cancelRiskyBulkConfirmation(clearPending: Bool = true) {
        showRiskyBulkConfirm = false
        acknowledgesDataLossRisk = false
        if clearPending { pendingBulkCaches = [] }
    }

    /// Closes every modal layer. Called when the popover goes away so it can never reopen
    /// into a half-presented state.
    private func dismissAllPresentations() {
        activeProjectSheet = nil
        showCleanConfirm = false
        showCleanSafeConfirm = false
        showCleanSelectedCachesConfirm = false
        showEmptyTrashConfirm = false
        showClearHistoryConfirm = false
        showDeleteFileConfirm = false
        cancelRiskyBulkConfirmation()
        diskMonitor.cleanFailure = nil
    }

    private var hasReviewItems: Bool {
        !diskMonitor.devCaches.isEmpty
            || !diskMonitor.projectArtifacts.isEmpty
            || !diskMonitor.largeFiles.isEmpty
            || diskMonitor.trashSizeBytes > 0
    }

    private func switchPrimaryMode(to mode: PrimaryMode) {
        dismissAllPresentations()
        activeScreen = .main
        isExpanded = false
        withAnimation(.easeInOut(duration: 0.16)) {
            primaryMode = mode
        }
    }

    private func openCleanerTab(_ tab: Tab) {
        primaryMode = .cleaner
        activeScreen = .main
        isExpanded = false
        selectedTab = tab
    }

    private func openCacheReview(mode: CacheCleanMode) {
        primaryMode = .cleaner
        cacheCleanMode = mode
        selectedCacheIDs = []
        activeScreen = .cleanCaches
    }

    private func openProjectReview() {
        primaryMode = .cleaner
        selectedArtifactIDs = []
        projectFilterMode = .all
        activeScreen = .cleanProjects
    }

    // MARK: - Review Mode
    private var reviewScreen: some View {
        let safeCaches = diskMonitor.devCaches.filter { $0.riskLevel == "safe" }
        let cautionCaches = diskMonitor.devCaches.filter { $0.riskLevel == "caution" }
        let riskyCaches = diskMonitor.devCaches.filter { $0.riskLevel == "risky" }
        let safeTotal = safeCaches.reduce(Int64(0)) { $0 + $1.size }
        let cautionTotal = cautionCaches.reduce(Int64(0)) { $0 + $1.size }
        let riskyTotal = riskyCaches.reduce(Int64(0)) { $0 + $1.size }
        let artifactTotal = diskMonitor.projectArtifacts.reduce(Int64(0)) { $0 + $1.size }
        let largeFileTotal = diskMonitor.largeFiles.reduce(Int64(0)) { $0 + $1.size }

        return VStack(spacing: 0) {
            headerView
            Divider()

            modeTitleBar(
                title: "Review",
                subtitle: "Safe cleanup and items that need your decision."
            )

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    if !hasReviewItems {
                        emptyModeState(
                            icon: "checkmark.shield.fill",
                            title: "Nothing needs attention",
                            message: "ClearDisk will place new findings here after the next scan."
                        )
                    } else {
                        if safeTotal > 0 || artifactTotal > 0 || diskMonitor.trashSizeBytes > 0 {
                            reviewSectionHeader(title: "Safe cleanup", detail: "Rebuildable or already in Trash")

                            VStack(spacing: 0) {
                                if safeTotal > 0 {
                                    reviewNavigationRow(
                                        icon: "checkmark.shield.fill",
                                        color: .green,
                                        title: "Rebuildable caches",
                                        subtitle: "\(safeCaches.count) known cache locations",
                                        size: safeTotal,
                                        actionTitle: "Review"
                                    ) { openCacheReview(mode: .safe) }
                                }

                                if artifactTotal > 0 {
                                    reviewNavigationRow(
                                        icon: "shippingbox.fill",
                                        color: .cyan,
                                        title: "Project artifacts",
                                        subtitle: "Build output only — source code is kept",
                                        size: artifactTotal,
                                        actionTitle: "Review"
                                    ) { openProjectReview() }
                                }

                                if diskMonitor.trashSizeBytes > 0 {
                                    reviewNavigationRow(
                                        icon: "trash.fill",
                                        color: .orange,
                                        title: "Trash",
                                        subtitle: "Permanent deletion is required to reclaim space",
                                        size: diskMonitor.trashSizeBytes,
                                        actionTitle: "Empty"
                                    ) { showEmptyTrashConfirm = true }
                                }
                            }
                            .background(Color.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        if cautionTotal > 0 || riskyTotal > 0 || largeFileTotal > 0 {
                            reviewSectionHeader(title: "Needs your decision", detail: "Never auto-selected")

                            VStack(spacing: 0) {
                                if cautionTotal > 0 {
                                    reviewNavigationRow(
                                        icon: "exclamationmark.circle.fill",
                                        color: .orange,
                                        title: "Caution caches",
                                        subtitle: "May require a large download or setup again",
                                        size: cautionTotal,
                                        actionTitle: "Inspect"
                                    ) { openCacheReview(mode: .moderate) }
                                }

                                if riskyTotal > 0 {
                                    reviewNavigationRow(
                                        icon: "exclamationmark.triangle.fill",
                                        color: .red,
                                        title: "Risky application data",
                                        subtitle: "May contain containers, sessions or local data",
                                        size: riskyTotal,
                                        actionTitle: "Inspect"
                                    ) { openCacheReview(mode: .everything) }
                                }

                                if largeFileTotal > 0 {
                                    reviewNavigationRow(
                                        icon: "doc.badge.magnifyingglass",
                                        color: .blue,
                                        title: "Large personal files",
                                        subtitle: "\(diskMonitor.largeFiles.count) files over 100 MB",
                                        size: largeFileTotal,
                                        actionTitle: "View"
                                    ) { openCleanerTab(.largeFiles) }
                                }
                            }
                            .background(Color.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)

            Divider()
            footerView
        }
    }

    // MARK: - Disk Space Mode
    private var diskSpaceScreen: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            modeTitleBar(
                title: "Disk Space",
                subtitle: "Current storage categories and large files."
            )

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    overviewContent

                    Button {
                        openCleanerTab(.largeFiles)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.magnifyingglass")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("View Large Files")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("Review files over 100 MB in known user folders")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footerView
        }
    }

    private func modeTitleBar(title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if diskMonitor.isScanning {
                ProgressView()
                    .scaleEffect(0.65)
            }
            Button {
                diskMonitor.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func reviewSectionHeader(title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(detail)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private func reviewNavigationRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        size: Int64,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(formatBytes(size))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(actionTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyModeState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(.green)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
    }

    // MARK: - Main Screen
    var mainScreen: some View {
        ZStack {
            if isExpanded {
                // Expanded view: full-height content with back button
                VStack(spacing: 0) {
                    ZStack {
                        // Center title
                        Text(selectedTab.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                        
                        // Left: back button, Right: refresh
                        HStack {
                            Button(action: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    if selectedTab == .diskSpace,
                                       compactDiskSpacePage != .locations {
                                        compactDiskSpacePage = .locations
                                    } else {
                                        isExpanded = false
                                    }
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 11))
                                    Text("Back")
                                        .font(.system(size: 12))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                            
                            Spacer()
                            
                            if diskMonitor.isScanning {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Button(action: { diskMonitor.scan() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help("Refresh")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    
                    Divider()
                    
                    ScrollView {
                        switch selectedTab {
                        case .diskSpace:
                            DiskSpaceCompactView(
                                store: diskSpaceStore,
                                diskMonitor: diskMonitor,
                                isExpanded: true,
                                page: $compactDiskSpacePage
                            )
                        case .overview:
                            overviewContent
                        case .developer:
                            developerContent
                        case .projects:
                            projectsContent
                        case .largeFiles:
                            largeFilesContent
                        }
                    }
                    .frame(maxHeight: .infinity)
                    
                    Divider()
                    
                    footerView
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            } else {
                // Normal view
                VStack(spacing: 0) {
                    // Header
                    headerView
                    
                    Divider()
                    

                    
                    // Cleanable summary card (only when there's stuff to clean)
                    let artifactTotal = diskMonitor.projectArtifacts.reduce(Int64(0)) { $0 + $1.size }
                    if selectedTab != .diskSpace &&
                        (diskMonitor.safeCleanable > 10_485_760 ||
                         diskMonitor.riskyCleanable > 10_485_760 ||
                         artifactTotal > 10_485_760) {
                        cleanableSummary
                        Divider()
                    }
                    
                    // Tab bar with expand button
                    HStack(spacing: 0) {
                        tabBar
                        
                        Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isExpanded = true } }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Divider()
                    
                    // Content
                    ScrollView {
                        switch selectedTab {
                        case .diskSpace:
                            DiskSpaceCompactView(
                                store: diskSpaceStore,
                                diskMonitor: diskMonitor,
                                isExpanded: false,
                                page: $compactDiskSpacePage
                            )
                        case .overview:
                            overviewContent
                        case .developer:
                            developerContent
                        case .projects:
                            projectsContent
                        case .largeFiles:
                            largeFilesContent
                        }
                    }
                    .frame(maxHeight: .infinity)
                    
                    Divider()
                    
                    // Footer
                    footerView
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
            
            // Onboarding overlay (first launch)
            if diskMonitor.isFirstLaunch && !diskMonitor.hasCompletedFirstScan {
                onboardingView
            }
        }
    }
    
    // MARK: - Cleanable Summary (Hero Card)
    var cleanableSummary: some View {
        let safeDevTotal = diskMonitor.devCaches.filter { $0.riskLevel == "safe" }.reduce(Int64(0)) { $0 + $1.size }
        let cautionDevTotal = diskMonitor.devCaches.filter { $0.riskLevel == "caution" }.reduce(Int64(0)) { $0 + $1.size }
        let riskyDevTotal = diskMonitor.devCaches.filter { $0.riskLevel == "risky" }.reduce(Int64(0)) { $0 + $1.size }
        let artifactTotal = diskMonitor.projectArtifacts.reduce(Int64(0)) { $0 + $1.size }
        let trashTotal = diskMonitor.trashSizeBytes
        let grandTotal = safeDevTotal + cautionDevTotal + riskyDevTotal + artifactTotal + trashTotal
        
        return VStack(spacing: 8) {
            // Big total number
            HStack(alignment: .firstTextBaseline) {
                Text(formatBytes(grandTotal))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
            }
            
            Text("reclaimable space found")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Segmented breakdown bar
            if grandTotal > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        let w = geo.size.width
                        if safeDevTotal > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green)
                                .frame(width: max(3, w * CGFloat(safeDevTotal) / CGFloat(grandTotal)))
                        }
                        if artifactTotal > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.cyan)
                                .frame(width: max(3, w * CGFloat(artifactTotal) / CGFloat(grandTotal)))
                        }
                        if riskyDevTotal > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.red.opacity(0.7))
                                .frame(width: max(3, w * CGFloat(riskyDevTotal) / CGFloat(grandTotal)))
                        }
                        if trashTotal > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange)
                                .frame(width: max(3, w * CGFloat(trashTotal) / CGFloat(grandTotal)))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            // Legend
            HStack(spacing: 12) {
                if safeDevTotal > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(formatBytes(safeDevTotal)) safe")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                if artifactTotal > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.cyan).frame(width: 6, height: 6)
                        Text("\(formatBytes(artifactTotal)) projects")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                if riskyDevTotal > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.red.opacity(0.7)).frame(width: 6, height: 6)
                        Text("\(formatBytes(riskyDevTotal)) risky")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                if trashTotal > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("\(formatBytes(trashTotal)) trash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            
            // Action buttons
            HStack(spacing: 8) {
                let devTotal = safeDevTotal + riskyDevTotal
                if devTotal > 0 {
                    Button(action: {
                        activeScreen = .cleanCaches
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                            Text("Clean Caches")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.green)
                }
                if artifactTotal > 0 {
                    Button(action: {
                        selectedArtifactIDs = []
                        projectFilterMode = .all
                        activeScreen = .cleanProjects
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                            Text("Sweep Project Caches")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color.mint.opacity(0.18))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.mint)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    
    // MARK: - Header
    var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ClearDisk")
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
                if diskMonitor.isScanning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button(action: { activeScreen = .settings }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Settings")
                Button(action: { diskMonitor.scan() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            
            // Storage bar
            storageBar
            
            HStack {
                Text("\(formatBytes(diskMonitor.usedSpace)) used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(formatBytes(diskMonitor.freeSpace)) free")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Storage forecast
            if let days = diskMonitor.forecastDaysUntilFull {
                HStack(spacing: 4) {
                    Image(systemName: days <= 30 ? "exclamationmark.triangle.fill" : "clock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(days <= 30 ? .red : .orange)
                    if days <= 7 {
                        Text("⚠️ Disk full in ~\(days) day\(days == 1 ? "" : "s")!")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                    } else if days <= 30 {
                        Text("Disk full in ~\(days) days at current rate")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    } else {
                        Text("~\(days) days until full (\(formatBytes(diskMonitor.dailyGrowthRate))/day)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else if diskMonitor.historySpanDays < 1 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Forecast: collecting data... (\(diskMonitor.historyDataPointCount) snapshot\(diskMonitor.historyDataPointCount == 1 ? "" : "s"))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
    }
    
    var storageBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                
                RoundedRectangle(cornerRadius: 6)
                    .fill(storageColor)
                    .frame(width: geo.size.width * CGFloat(diskMonitor.usedPercentage) / 100.0)
                
                Text("\(diskMonitor.usedPercentage)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(radius: 1)
                    .padding(.leading, 8)
            }
        }
        .frame(height: 24)
    }
    
    var storageColor: Color {
        if diskMonitor.usedPercentage > 90 { return .red }
        if diskMonitor.usedPercentage > 75 { return .orange }
        return .blue
    }
    
    // MARK: - Tab Bar
    var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle()) // Makes entire area clickable, not just text
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.1)
                                : Color.clear
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    // MARK: - Overview Tab
    var overviewContent: some View {
        VStack(spacing: 0) {
            // Cleanup result banner
            if diskMonitor.showCleanResultBanner && diskMonitor.lastCleanedAmount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(diskMonitor.lastCleanOutcome == .reclaimedSpace
                             ? "Reclaimed \(formatBytes(diskMonitor.lastCleanedAmount))"
                             : "Moved \(formatBytes(diskMonitor.lastCleanedAmount)) to Trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                        if diskMonitor.lastCleanOutcome == .movedToTrash {
                            Text("Empty Trash to reclaim this disk space.")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // Categories with proportional bars
            let maxSize = diskMonitor.categories.first?.size ?? 1
            ForEach(diskMonitor.categories) { cat in
                categoryRow(cat, maxSize: maxSize)
            }
            
            // Trash
            let trash = diskMonitor.trashSizeBytes
            if trash > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                        .frame(width: 24)
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trash")
                            .font(.system(size: 12))
                        
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.3))
                                .frame(width: max(4, geo.size.width * CGFloat(trash) / CGFloat(maxSize)))
                        }
                        .frame(height: 4)
                    }
                    
                    Text(formatBytes(trash))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 65, alignment: .trailing)
                    
                    Button("Empty") {
                        showEmptyTrashConfirm = true
                    }
                    .font(.system(size: 10))
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            
            // Storage History Chart (safe: only shows with valid data)
            if diskMonitor.usageHistory.count >= 2, diskMonitor.totalSpace > 0 {
                Divider()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                
                storageHistoryChart
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
    }
    
    func categoryRow(_ cat: DiskCategory, maxSize: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: cat.icon)
                .font(.system(size: 14))
                .frame(width: 24)
                .foregroundColor(categoryColor(cat.name))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.name)
                    .font(.system(size: 12))
                
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(categoryColor(cat.name).opacity(0.3))
                        .frame(width: max(4, geo.size.width * CGFloat(cat.size) / CGFloat(maxSize)))
                }
                .frame(height: 4)
            }
            
            Text(formatBytes(cat.size))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
    
    func categoryColor(_ name: String) -> Color {
        switch name {
        case "Developer": return .purple
        case "Caches": return .red
        case "Applications": return .blue
        case "Documents": return .cyan
        case "Downloads": return .green
        case "Desktop": return .indigo
        case "Mail": return .orange
        case "Music": return .pink
        case "Movies": return .yellow
        case "Photos": return .mint
        default: return .gray
        }
    }
    
    // MARK: - Storage History Chart
    var storageHistoryChart: some View {
        let history = diskMonitor.usageHistory
        let gbValues = history.map { Double($0.usedBytes) / 1_073_741_824 }
        let minGB = (gbValues.min() ?? 0)
        let maxGB = (gbValues.max() ?? 100)
        let range = max(maxGB - minGB, 1.0) // At least 1 GB range
        let yMin = max(0, minGB - range * 0.3)
        let yMax = maxGB + range * 0.3
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("Storage Trend")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(diskMonitor.historySpanDays)d history")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            
            Chart {
                ForEach(Array(history.enumerated()), id: \.offset) { _, snapshot in
                    let date = Date(timeIntervalSince1970: snapshot.timestamp)
                    let usedGB = Double(snapshot.usedBytes) / 1_073_741_824
                    
                    LineMark(
                        x: .value("Time", date),
                        y: .value("Used", usedGB)
                    )
                    .foregroundStyle(storageColor)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value("Time", date),
                        y: .value("Used", usedGB)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [storageColor.opacity(0.25), storageColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: yMin...yMax)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray.opacity(0.15))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray.opacity(0.15))
                    AxisValueLabel {
                        if let gb = value.as(Double.self) {
                            Text("\(Int(gb)) GB")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 100)
            
            // Growth info
            if diskMonitor.dailyGrowthRate != 0 {
                HStack(spacing: 4) {
                    Image(systemName: diskMonitor.dailyGrowthRate > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9))
                        .foregroundColor(diskMonitor.dailyGrowthRate > 0 ? .orange : .green)
                    Text(diskMonitor.dailyGrowthRate > 0
                         ? "+\(formatBytes(diskMonitor.dailyGrowthRate))/day"
                         : "\(formatBytes(abs(diskMonitor.dailyGrowthRate)))/day freed")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if let days = diskMonitor.forecastDaysUntilFull {
                        Spacer()
                        Text("~\(days)d until full")
                            .font(.system(size: 10))
                            .foregroundColor(days <= 30 ? .red : .orange)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
    }
    
    // MARK: - Developer Tab
    
    /// Groups caches by their group field, preserving order
    /// Returns: [(groupName: String?, caches: [DevCache])]
    /// Grouped items appear as a single collapsible row, ungrouped items appear individually
    private var groupedDevCaches: [(key: String?, caches: [DevCache])] {
        var result: [(key: String?, caches: [DevCache])] = []
        var groupMap: [String: Int] = [:] // group name -> index in result
        
        for cache in diskMonitor.devCaches {
            if let group = cache.group {
                if let idx = groupMap[group] {
                    result[idx].caches.append(cache)
                } else {
                    groupMap[group] = result.count
                    result.append((key: group, caches: [cache]))
                }
            } else {
                result.append((key: nil, caches: [cache]))
            }
        }
        return result
    }
    
    private func groupIcon(_ groupName: String) -> String {
        switch groupName {
        case "Xcode": return "hammer.fill"
        case "VS Code": return "laptopcomputer"
        case "AI Tools": return "brain"
        case "Ruby": return "diamond.fill"
        case "Android": return "apps.iphone"
        default: return "folder.fill"
        }
    }
    
    var developerContent: some View {
        VStack(spacing: 2) {
            if diskMonitor.devCaches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                    Text("No developer caches found")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Your disk is clean!")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
            } else {
                let totalDev = diskMonitor.devCaches.reduce(Int64(0)) { $0 + $1.size }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Developer Caches")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(diskMonitor.devCaches.count) locations found")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(totalDev))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.04))
                
                ForEach(Array(groupedDevCaches.enumerated()), id: \.offset) { _, entry in
                    if let groupName = entry.key {
                        // Grouped items with expand/collapse
                        cacheGroupRow(groupName: groupName, caches: entry.caches)
                            .padding(.bottom, 4)
                    } else {
                        // Standalone items
                        ForEach(entry.caches) { cache in
                            devCacheRow(cache)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    func cacheGroupRow(groupName: String, caches: [DevCache]) -> some View {
        let totalSize = caches.reduce(Int64(0)) { $0 + $1.size }
        let isGroupExpanded = expandedGroups.contains(groupName)
        let sortedCaches = caches.sorted { $0.size > $1.size }
        let topNames = sortedCaches.prefix(3).map { $0.name.replacingOccurrences(of: "\(groupName) ", with: "").replacingOccurrences(of: "Xcode ", with: "") }
        let preview = topNames.joined(separator: ", ")
        
        return VStack(spacing: 0) {
            // Group header row - entire row is clickable
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isGroupExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.purple.opacity(0.7))
                        .frame(width: 10)
                    Image(systemName: groupIcon(groupName))
                        .font(.system(size: 14))
                        .frame(width: 22)
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(groupName)
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(caches.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.purple.opacity(0.6)))
                        }
                        if !isGroupExpanded {
                            Text(preview)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer()
                
                Text(formatBytes(totalSize))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.purple.opacity(0.8))
                
                // Clean entire group
                Button(action: {
                    selectedCacheIDs = Set(caches.map { $0.id })
                    requestBulkClean(caches)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .disabled(isCleaning)
                .help("Clean all \(groupName) caches")
                
                // Reveal first item in Finder
                Button(action: {
                    if let first = caches.first {
                        diskMonitor.revealInFinder(first.path)
                    }
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .help("Show in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.purple.opacity(0.05))
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedGroups.contains(groupName) {
                        expandedGroups.remove(groupName)
                    } else {
                        expandedGroups.insert(groupName)
                    }
                }
            }
            
            // Expanded child items
            if isGroupExpanded {
                VStack(spacing: 0) {
                    ForEach(caches) { cache in
                        devCacheRow(cache)
                    }
                }
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.purple.opacity(0.2))
                        .frame(width: 2)
                        .padding(.leading, 16)
                        .padding(.vertical, 4)
                }
            }
        }
    }
    
    func devCacheRow(_ cache: DevCache) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: cache.icon)
                    .font(.system(size: 14))
                    .frame(width: 24)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(cache.riskEmoji)
                            .font(.system(size: 10))
                            .help(cache.riskDescription)
                        Text(cache.name)
                            .font(.system(size: 12))
                        if let days = cache.daysSinceAccess {
                            Text("\(days)d ago")
                                .font(.system(size: 9))
                                .foregroundColor(days > 60 ? .orange : .secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(days > 60 ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
                                )
                        }
                    }
                    // Cache description tooltip on the path line
                    Text(cache.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cache.cacheDescription)
                }
                Spacer()
                Text(formatBytes(cache.size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: {
                    cacheToClean = cache
                    showCleanConfirm = true
                }) {
                    if isCleaning {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .disabled(isCleaning)
                .help("Clean \(cache.name)")
                
                Button(action: {
                    diskMonitor.revealInFinder(cache.path)
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .help("Show in Finder")
            }
            
            // Description line (subtle, always visible)
            if !cache.cacheDescription.isEmpty {
                Text(cache.cacheDescription)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.leading, 36)
                    .padding(.top, 1)
                    .lineLimit(1)
            }
            
            // DerivedData project breakdown
            if let detail = cache.detail {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 8))
                        .foregroundColor(.purple.opacity(0.6))
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundColor(.purple.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 36)
                .padding(.top, 1)
            }
            
            // Smart suggestion
            if let suggestion = cache.suggestion {
                Text(suggestion)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .padding(.leading, 36)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
    
    // MARK: - Projects Tab (kondo-style artifact scanner)
    var projectsContent: some View {
        VStack(spacing: 2) {
            if diskMonitor.projectArtifacts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No project caches found")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Scans ~/Documents, ~/Developer, ~/Projects, ~/Code, ~/Desktop")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
            } else {
                let totalArtifacts = diskMonitor.projectArtifacts.reduce(Int64(0)) { $0 + $1.size }
                let staleCount = diskMonitor.projectArtifacts.filter { $0.isStale }.count
                VStack(spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Per-Project Caches")
                                .font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.green)
                                Text("Cleaning removes cache only — your source code stays intact")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Text("\(diskMonitor.projectArtifacts.count) found · \(staleCount) stale (>30 days)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(formatBytes(totalArtifacts))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                            Button(action: { activeProjectSheet = .history }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("History")
                                        .font(.system(size: 10, weight: .medium))
                                    if !diskMonitor.projectCleanHistory.isEmpty {
                                        Text("\(diskMonitor.projectCleanHistory.count)")
                                            .font(.system(size: 9, weight: .semibold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 0)
                                            .background(Color.mint.opacity(0.25))
                                            .cornerRadius(6)
                                    }
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.mint.opacity(0.12))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.mint)
                            .help("View previously cleaned project caches")
                        }
                    }
                    // Sort picker
                    HStack(spacing: 0) {
                        ForEach(ProjectSortMode.allCases, id: \.self) { mode in
                            Button(action: { projectSortMode = mode }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 10, weight: projectSortMode == mode ? .semibold : .regular))
                                    .foregroundColor(projectSortMode == mode ? .accentColor : .secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                    .background(
                                        projectSortMode == mode
                                            ? Color.accentColor.opacity(0.1)
                                            : Color.clear
                                    )
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.04))
                
                ForEach(sortedProjectArtifacts) { artifact in
                    projectArtifactRow(artifact)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    var sortedProjectArtifacts: [ProjectArtifact] {
        switch projectSortMode {
        case .size:
            return diskMonitor.projectArtifacts.sorted { $0.size > $1.size }
        case .date:
            return diskMonitor.projectArtifacts.sorted {
                let dA = $0.daysSinceModified ?? 0
                let dB = $1.daysSinceModified ?? 0
                if dA != dB { return dA > dB }
                return $0.size > $1.size
            }
        case .name:
            return diskMonitor.projectArtifacts.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        }
    }
    
    func projectArtifactRow(_ artifact: ProjectArtifact) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: artifact.typeIcon)
                    .font(.system(size: 14))
                    .frame(width: 24)
                    .foregroundColor(artifact.isStale ? .orange : .purple)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(artifact.projectName)
                            .font(.system(size: 12, weight: .medium))
                        Text(artifact.artifactName)
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.purple.opacity(0.6))
                            )
                        Text(artifact.projectType)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        if let days = artifact.daysSinceModified {
                            Text("\(days)d")
                                .font(.system(size: 9))
                                .foregroundColor(days > 30 ? .orange : .secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(days > 30 ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
                                )
                        }
                    }
                    Text(artifact.projectPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(formatBytes(artifact.size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: {
                    artifactToClean = artifact
                    activeProjectSheet = .cleanConfirm
                }) {
                    if isCleaning {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    } else {
                        // Same affordance as the Developer tab: this moves a directory to the Trash,
                        // so it reads as a trash action, not as a "magic optimize".
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .disabled(isCleaning)
                .help("Clean \(artifact.artifactName) cache only — your source code is kept")
                
                Button(action: {
                    diskMonitor.revealInFinder(artifact.projectPath)
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .help("Show in Finder")
            }
            
            if artifact.isStale {
                Text("⚠️ Stale — not modified for \(artifact.daysSinceModified ?? 0) days")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .padding(.leading, 36)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
    
    // MARK: - Large Files Tab
    var largeFilesContent: some View {
        VStack(spacing: 4) {
            if diskMonitor.largeFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.clock")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No files larger than 100 MB found")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Scanned: Downloads, Documents, Desktop, Movies, Music, Pictures")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
            } else {
                let folderOrder = ["Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures"]
                let grouped = Dictionary(grouping: diskMonitor.largeFiles, by: { $0.folder })
                ForEach(folderOrder, id: \.self) { folderName in
                    if let files = grouped[folderName], !files.isEmpty {
                        LargeFileFolderCard(
                            folderName: folderName,
                            files: files,
                            expandedFolder: $expandedLargeFileFolder,
                            onDelete: { file in
                                fileToDelete = file
                                showDeleteFileConfirm = true
                            },
                            onReveal: { file in diskMonitor.revealInFinder(file.path) }
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Onboarding View
    var onboardingView: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            
            VStack(spacing: 16) {
                Spacer()
                
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                
                Text("Welcome to ClearDisk")
                    .font(.system(size: 20, weight: .bold))
                
                Text("Your macOS disk analyzer for developers")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 10) {
                    onboardingFeature(icon: "magnifyingglass", text: "Scans developer caches (Xcode, npm, pip, etc.)")
                    onboardingFeature(icon: "trash", text: "Moves files to Trash before permanent deletion")
                    onboardingFeature(icon: "bell", text: "Alerts when disk space is running low")
                    onboardingFeature(icon: "chart.line.uptrend.xyaxis", text: "Forecasts when your disk will be full")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                
                // Permission status
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: diskMonitor.notificationPermission == .granted ? "checkmark.circle.fill" : diskMonitor.notificationPermission == .denied ? "xmark.circle.fill" : "circle")
                            .foregroundColor(diskMonitor.notificationPermission == .granted ? .green : diskMonitor.notificationPermission == .denied ? .red : .secondary)
                            .font(.system(size: 12))
                        Text("Notifications: \(permissionLabel(diskMonitor.notificationPermission))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 32)
                
                Spacer()
                
                if diskMonitor.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning your disk...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button(action: {
                        diskMonitor.markOnboardingComplete()
                    }) {
                        Text("Get Started")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 200, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Spacer()
            }
        }
    }
    
    func onboardingFeature(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
    }
    
    func permissionLabel(_ state: PermissionState) -> String {
        switch state {
        case .granted: return "Enabled"
        case .denied: return "Denied"
        case .unknown: return "Checking..."
        }
    }
    
    // MARK: - Settings Screen
    var settingsScreen: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Button(action: { activeScreen = .main }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                // Invisible balancer
                Text("Back__")
                    .font(.system(size: 13))
                    .hidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Notifications section
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Notifications", systemImage: "bell.fill")
                            .font(.system(size: 13, weight: .semibold))
                        
                        Text("ClearDisk sends alerts when your disk usage reaches 80% or 90%.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        HStack {
                            switch diskMonitor.notificationPermission {
                            case .granted:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                                Text("Notifications enabled")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                Spacer()
                                Button("Open Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.system(size: 11))
                                .controlSize(.small)
                            case .denied:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 14))
                                Text("Notifications disabled")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                Spacer()
                                Button("Enable in Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.system(size: 11))
                                .controlSize(.small)
                            case .unknown:
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 14))
                                Text("Permission not requested")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                Spacer()
                                Button("Enable Notifications") {
                                    diskMonitor.setupNotifications()
                                }
                                .font(.system(size: 11))
                                .controlSize(.small)
                            }
                        }
                        
                        if diskMonitor.notificationPermission == .denied {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Text("To enable notifications, open System Settings > Notifications > ClearDisk and turn on \"Allow Notifications\".")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                    
                    // Launch at Login section
                    VStack(alignment: .leading, spacing: 10) {
                        Label("General", systemImage: "gearshape.fill")
                            .font(.system(size: 13, weight: .semibold))
                        
                        Toggle(isOn: $launchAtLogin) {
                            Text("Launch at Login")
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                print("Failed to update login item: \(error)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                    
                    // About section
                    VStack(alignment: .leading, spacing: 10) {
                        Label("About", systemImage: "info.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        
                        HStack {
                            Text("Version")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(AppInfo.version)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        
                        HStack {
                            Text("GitHub")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("bysiber/ClearDisk") {
                                if let url = URL(string: "https://github.com/bysiber/ClearDisk") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 11))
                            .controlSize(.small)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Updates")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Check for Updates") {
                                if let url = URL(string: "https://github.com/bysiber/cleardisk/releases/latest") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 11))
                            .controlSize(.small)
                        }
                        
                        Text("Opens GitHub releases page. No network requests from ClearDisk.")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            diskMonitor.checkNotificationStatus()
            // Register login item if enabled (handles first launch)
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            }
        }
    }
    
    // MARK: - Permission Banner
    var permissionBanner: some View {
        VStack(spacing: 4) {
            if diskMonitor.notificationPermission == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Notifications disabled — you won't get disk space alerts")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 9))
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.06))
    }
    
    // MARK: - Clean Caches Sub-Screen
    var cleanCachesScreen: some View {
        let cachesToShow: [DevCache]
        switch cacheCleanMode {
        case .safe:
            cachesToShow = diskMonitor.devCaches.filter { $0.riskLevel == "safe" }
        case .moderate:
            cachesToShow = diskMonitor.devCaches.filter { $0.riskLevel != "risky" }
        case .everything:
            cachesToShow = diskMonitor.devCaches
        }
        let selectedSize = cachesToShow.filter { selectedCacheIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        let selectedCount = cachesToShow.filter { selectedCacheIDs.contains($0.id) }.count
        
        return VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Button(action: { activeScreen = .main }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
                Text("Clean Caches")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Invisible balancer
                Text("Back__")
                    .font(.system(size: 12))
                    .hidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            Divider()
            
            // Filter + Select controls
            HStack(spacing: 6) {
                // Mode picker
                Button(action: {
                    cacheCleanMode = .safe
                    selectedCacheIDs = []
                }) {
                    Text("Safe")
                        .font(.system(size: 10, weight: cacheCleanMode == .safe ? .semibold : .regular))
                        .foregroundColor(cacheCleanMode == .safe ? .green : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(cacheCleanMode == .safe ? Color.green.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    cacheCleanMode = .moderate
                    selectedCacheIDs = []
                }) {
                    Text("Moderate")
                        .font(.system(size: 10, weight: cacheCleanMode == .moderate ? .semibold : .regular))
                        .foregroundColor(cacheCleanMode == .moderate ? .orange : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(cacheCleanMode == .moderate ? Color.orange.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    cacheCleanMode = .everything
                    selectedCacheIDs = []
                }) {
                    Text("Everything")
                        .font(.system(size: 10, weight: cacheCleanMode == .everything ? .semibold : .regular))
                        .foregroundColor(cacheCleanMode == .everything ? .red : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(cacheCleanMode == .everything ? Color.red.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Select All / Deselect All
                Button(action: {
                    if selectedCacheIDs.count == cachesToShow.count {
                        selectedCacheIDs = []
                    } else {
                        selectedCacheIDs = Set(cachesToShow.map { $0.id })
                    }
                }) {
                    Text(selectedCacheIDs.count == cachesToShow.count && !cachesToShow.isEmpty ? "Deselect All" : "Select All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            Divider()
            
            // Cache list with checkboxes
            ScrollView {
                VStack(spacing: 0) {
                    if cachesToShow.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "externaldrive.badge.checkmark")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            Text("No caches found")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(cachesToShow) { cache in
                            let isSelected = selectedCacheIDs.contains(cache.id)
                            Button(action: {
                                if isSelected {
                                    selectedCacheIDs.remove(cache.id)
                                } else {
                                    selectedCacheIDs.insert(cache.id)
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14))
                                        .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                                    
                                    Circle()
                                        .fill(cache.riskLevel == "risky" ? Color.red : cache.riskLevel == "caution" ? Color.yellow : Color.green)
                                        .frame(width: 8, height: 8)
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cache.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(cache.cacheDescription)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(formatBytes(cache.size))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(isSelected ? Color.accentColor.opacity(0.04) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Risky warning (only in Everything mode)
                        if cacheCleanMode == .everything {
                            let riskySelected = diskMonitor.devCaches.filter { $0.riskLevel == "risky" && selectedCacheIDs.contains($0.id) }
                            if !riskySelected.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.red)
                                        Text("\(riskySelected.count) risky cache(s) selected:")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.red)
                                        Spacer()
                                    }
                                    ForEach(riskySelected) { cache in
                                        Text("• \(cache.name) — \(formatBytes(cache.size))")
                                            .font(.system(size: 9))
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                    Text("May contain data that cannot be rebuilt")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .background(Color.red.opacity(0.06))
                                .cornerRadius(8)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // Selection summary + action
            HStack {
                Text("\(selectedCount) selected · \(formatBytes(selectedSize))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            
            Button(action: {
                let selected = cachesToShow.filter { selectedCacheIDs.contains($0.id) }
                requestBulkClean(selected)
            }) {
                HStack(spacing: 6) {
                    if isCleaning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12))
                    }
                    Text(isCleaning ? "Cleaning..." : "Clean Selected (\(formatBytes(selectedSize)))")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selectedCount > 0 && !isCleaning ? cleanButtonColor : Color.gray.opacity(0.3))
                .foregroundColor(selectedCount > 0 && !isCleaning ? .white : .secondary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0 || isCleaning)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
        .frame(width: Layout.contentWidth, height: Layout.popoverHeight)
    }
    
    var cleanButtonColor: Color {
        switch cacheCleanMode {
        case .safe: return .green
        case .moderate: return .orange
        case .everything: return .red
        }
    }
    
    // MARK: - Clean Projects Sub-Screen
    var cleanProjectsScreen: some View {
        let filtered = filteredProjectArtifacts
        let selectedSize = filtered.filter { selectedArtifactIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        let selectedCount = filtered.filter { selectedArtifactIDs.contains($0.id) }.count
        
        return VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Button(action: { activeScreen = .main }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
                Text("Sweep Project Caches")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { activeProjectSheet = .history }) {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                        Text("History")
                            .font(.system(size: 12))
                        if !diskMonitor.projectCleanHistory.isEmpty {
                            Text("\(diskMonitor.projectCleanHistory.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.mint.opacity(0.25))
                                .foregroundColor(.mint)
                                .cornerRadius(7)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("View previously cleaned project caches")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            Divider()
            
            // Filter + Select controls
            HStack(spacing: 6) {
                // Filter picker
                ForEach(ProjectFilterMode.allCases, id: \.self) { mode in
                    Button(action: {
                        projectFilterMode = mode
                        selectedArtifactIDs = []
                    }) {
                        Text(mode.rawValue)
                            .font(.system(size: 10, weight: projectFilterMode == mode ? .semibold : .regular))
                            .foregroundColor(projectFilterMode == mode ? .accentColor : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .background(projectFilterMode == mode ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                // Select All / Deselect All
                Button(action: {
                    if selectedArtifactIDs.count == filtered.count {
                        selectedArtifactIDs = []
                    } else {
                        selectedArtifactIDs = Set(filtered.map { $0.id })
                    }
                }) {
                    Text(selectedArtifactIDs.count == filtered.count && !filtered.isEmpty ? "Deselect All" : "Select All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            Divider()
            
            // Artifact list with checkboxes
            ScrollView {
                VStack(spacing: 0) {
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            Text("No artifacts match the filter")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(filtered) { artifact in
                            let isSelected = selectedArtifactIDs.contains(artifact.id)
                            Button(action: {
                                if isSelected {
                                    selectedArtifactIDs.remove(artifact.id)
                                } else {
                                    selectedArtifactIDs.insert(artifact.id)
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14))
                                        .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                                    
                                    Image(systemName: artifact.typeIcon)
                                        .font(.system(size: 14))
                                        .frame(width: 20)
                                        .foregroundColor(artifact.isStale ? .orange : .purple)
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(artifact.projectName)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.primary)
                                            Text(artifact.artifactName)
                                                .font(.system(size: 9))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.5)))
                                            if let days = artifact.daysSinceModified, days > 30 {
                                                Text("\(days)d")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        Text(artifact.projectType)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(formatBytes(artifact.size))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(isSelected ? Color.accentColor.opacity(0.04) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // Selection summary + action
            HStack {
                Text("\(selectedCount) selected · \(formatBytes(selectedSize))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            
            Button(action: {
                isCleaning = true
                let toClean = diskMonitor.projectArtifacts.filter { selectedArtifactIDs.contains($0.id) }
                diskMonitor.projectArtifacts.removeAll { selectedArtifactIDs.contains($0.id) }
                for artifact in toClean {
                    diskMonitor.cleanProjectArtifact(artifact)
                }
                selectedArtifactIDs = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isCleaning = false
                    activeScreen = .main
                }
            }) {
                HStack(spacing: 6) {
                    if isCleaning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        // Matches the Developer tab's bulk clean button.
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12))
                    }
                    Text(isCleaning ? "Cleaning..." : "Clean Selected Caches (\(formatBytes(selectedSize)))")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selectedCount > 0 && !isCleaning ? Color.orange : Color.gray.opacity(0.3))
                .foregroundColor(selectedCount > 0 && !isCleaning ? .white : .secondary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0 || isCleaning)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
        .frame(width: Layout.contentWidth, height: Layout.popoverHeight)
    }
    
    var filteredProjectArtifacts: [ProjectArtifact] {
        let sorted = sortedProjectArtifacts
        switch projectFilterMode {
        case .all:
            return sorted
        case .stale:
            return sorted.filter { $0.isStale }
        }
    }
    
    // MARK: - Footer
    var footerView: some View {
        HStack {
            if diskMonitor.totalMovedToTrash > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Moved via ClearDisk: \(formatBytes(diskMonitor.totalMovedToTrash))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("ClearDisk \(AppInfo.displayVersion)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 11))
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Large File Folder Card
struct LargeFileFolderCard: View {
    let folderName: String
    let files: [LargeFile]
    @Binding var expandedFolder: String?
    let onDelete: (LargeFile) -> Void
    let onReveal: (LargeFile) -> Void

    var isOpen: Bool { expandedFolder == folderName }
    var totalSize: Int64 { files.reduce(Int64(0)) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedFolder = isOpen ? nil : folderName
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: folderIcon)
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folderName)
                            .font(.system(size: 12, weight: .medium))
                        Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(totalSize))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Divider().padding(.horizontal, 12)
                ForEach(files.sorted { $0.size > $1.size }) { file in
                    fileRowView(file)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
        .padding(.horizontal, 4)
    }

    private var folderIcon: String {
        switch folderName {
                case "Downloads": return "arrow.down.circle.fill"
        case "Documents": return "doc.fill"
        case "Desktop": return "menubar.dock.rectangle"
        case "Movies": return "film.fill"
        case "Music": return "music.note"
        case "Pictures": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private func fileIconName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "mkv": return "film.fill"
        case "dmg", "iso", "img": return "externaldrive.fill"
        case "zip", "tar", "gz", "rar", "7z": return "doc.zipper"
        case "app": return "app.fill"
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "heic", "tiff": return "photo.fill"
        default: return "doc.fill"
        }
    }

    private func fileRowView(_ file: LargeFile) -> some View {
        HStack {
            Image(systemName: fileIconName(file.name))
                .font(.system(size: 14))
                .frame(width: 24)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(file.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Button(action: { onDelete(file) }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .help("Move to Trash")
            Button(action: { onReveal(file) }) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.blue)
            .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - Custom Confirmation Sheet (no app icon, unlike .alert)
struct CleanCacheConfirmSheet: View {
    let artifact: ProjectArtifact?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Cache Only")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Source code is never touched")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            if let artifact = artifact {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clean **\(artifact.artifactName)** cache from **\(artifact.projectName)**?")
                        .font(.system(size: 12))
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 11))
                        Text("Only the cache directory is moved to Trash. Your source files stay.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Divider().padding(.vertical, 2)
                    
                    detailRow(label: "Frees", value: formatBytes(artifact.size), valueColor: .mint, bold: true)
                    detailRow(label: "Type",  value: artifact.projectType)
                    detailRow(label: "Path",  value: artifact.artifactPath, mono: true)
                    
                    Text("Re-run your build/install command to regenerate.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)
            }
            
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Clean Cache")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        // Width comes from the popover overlay that hosts this view (see projectSheetOverlay).
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, valueColor: Color = .primary, mono: Bool = false, bold: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: bold ? .semibold : .regular, design: mono ? .monospaced : .default))
                .foregroundColor(valueColor)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer()
        }
    }
}

// MARK: - Project Clean History Sheet
struct ProjectCleanHistorySheet: View {
    let entries: [ProjectCleanHistoryEntry]
    let onClose: () -> Void
    let onClearAll: () -> Void
    
    private var totalFreed: Int64 {
        entries.reduce(Int64(0)) { $0 + $1.size }
    }
    
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cleanup History")
                        .font(.system(size: 14, weight: .semibold))
                    if entries.isEmpty {
                        Text("No cleanups recorded yet")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(entries.count) cleanup\(entries.count == 1 ? "" : "s") · \(formatBytes(totalFreed)) freed")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if !entries.isEmpty {
                    Button(action: onClearAll) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Clear")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red.opacity(0.8))
                    .help("Clear local history log (does not affect Trash)")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            
            Divider()
            
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Nothing here yet")
                        .font(.system(size: 12, weight: .medium))
                    Text("Cleaned project caches will appear here.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 50)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            historyRow(entry)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            
            Divider()
            HStack {
                Text("Source code is never touched — only listed cache directories were moved to Trash.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // Size and background come from the popover overlay that hosts this view — a fixed width
        // here would be wider than the popover itself and get clipped.
    }

    @ViewBuilder
    private func historyRow(_ entry: ProjectCleanHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.mint)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.artifactName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                    Text(entry.projectType)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(4)
                    Spacer()
                    Text(formatBytes(entry.size))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.mint)
                }
                Text(entry.projectPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.dateFormatter.string(from: entry.cleanedAt))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            
            Button(action: {
                NSWorkspace.shared.selectFile(entry.projectPath, inFileViewerRootedAtPath: "")
            }) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show project in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
