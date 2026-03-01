import SwiftUI

// MARK: - Main View
struct MainView: View {
    @ObservedObject var diskMonitor: DiskMonitor
    @State private var selectedTab: Tab = .developer
    @State private var showCleanConfirm = false
    @State private var showCleanAllConfirm = false
    @State private var showCleanSafeConfirm = false
    @State private var showCleanArtifactConfirm = false
    @State private var cacheToClean: DevCache?
    @State private var artifactToClean: ProjectArtifact?
    @State private var projectSortMode: ProjectSortMode = .size
    @State private var activeScreen: ActiveScreen = .main
    @State private var cacheCleanMode: CacheCleanMode = .safe
    @State private var selectedArtifactIDs: Set<UUID> = []
    @State private var selectedCacheIDs: Set<UUID> = []
    @State private var showCleanSelectedCachesConfirm = false
    @State private var projectFilterMode: ProjectFilterMode = .all
    @State private var isCleaning = false
    
    enum Tab: String, CaseIterable {
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
    }
    
    enum CacheCleanMode {
        case safe
        case all
    }
    
    enum ProjectFilterMode: String, CaseIterable {
        case all = "All"
        case stale = "Stale (>30d)"
    }
    
    var body: some View {
        Group {
            switch activeScreen {
            case .cleanCaches:
                cleanCachesScreen
            case .cleanProjects:
                cleanProjectsScreen
            case .main:
                mainScreen
            }
        }
        .frame(width: 380, height: 540)
        .alert("Clean Cache", isPresented: $showCleanConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                if let cache = cacheToClean {
                    isCleaning = true
                    diskMonitor.cleanDevCache(cache)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isCleaning = false }
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
                diskMonitor.cleanSafeCaches()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCleaning = false }
            }
        } message: {
            let safeCaches = diskMonitor.devCaches.filter { $0.riskLevel != "risky" }
            let safeTotal = safeCaches.reduce(Int64(0)) { $0 + $1.size }
            let xcodeWarning = diskMonitor.isXcodeRunning()
                ? "\n\n⚠️ Xcode is currently running! Close Xcode first for best results."
                : ""
            Text("Clean \(safeCaches.count) safe/caution caches?\nThis will move \(formatBytes(safeTotal)) to Trash.\n\nRisky caches (like Docker) are NOT included.\nFiles go to Trash — you can recover them.\(xcodeWarning)")
        }
        .alert("Clean ALL Developer Caches", isPresented: $showCleanAllConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All (Including Risky)", role: .destructive) {
                isCleaning = true
                diskMonitor.cleanAllDevCaches()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCleaning = false }
            }
        } message: {
            let total = diskMonitor.devCaches.reduce(Int64(0)) { $0 + $1.size }
            let riskyCount = diskMonitor.devCaches.filter { $0.riskLevel == "risky" }.count
            let riskyNote = riskyCount > 0 ? "\n\n🔴 WARNING: \(riskyCount) risky cache(s) included — may contain data that cannot be rebuilt (e.g. Docker volumes, unsaved projects)." : ""
            let xcodeWarning = diskMonitor.isXcodeRunning()
                ? "\n\n⚠️ Xcode is currently running! Close Xcode first for best results."
                : ""
            Text("Move ALL developer caches to Trash?\nThis will free \(formatBytes(total)).\n\n\(diskMonitor.devCaches.count) cache locations will be cleaned.\nFiles go to Trash — you can recover them.\(riskyNote)\(xcodeWarning)")
        }
        .alert("Clean Project Artifact", isPresented: $showCleanArtifactConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                if let artifact = artifactToClean {
                    isCleaning = true
                    diskMonitor.cleanProjectArtifact(artifact)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isCleaning = false }
                }
            }
        } message: {
            if let artifact = artifactToClean {
                Text("Delete \(artifact.artifactName) from \(artifact.projectName)?\n\nThis will move \(formatBytes(artifact.size)) to Trash.\n\nType: \(artifact.projectType)\nPath: \(artifact.artifactPath)\n\nRe-run your build/install command to restore.")
            }
        }
        .alert("Clean Selected Caches", isPresented: $showCleanSelectedCachesConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                isCleaning = true
                let toClean = diskMonitor.devCaches.filter { selectedCacheIDs.contains($0.id) }
                for cache in toClean {
                    diskMonitor.cleanDevCache(cache)
                }
                selectedCacheIDs = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isCleaning = false
                    activeScreen = .main
                }
            }
        } message: {
            let toClean = diskMonitor.devCaches.filter { selectedCacheIDs.contains($0.id) }
            let totalSize = toClean.reduce(Int64(0)) { $0 + $1.size }
            let riskyCount = toClean.filter { $0.riskLevel == "risky" }.count
            let riskyNote = riskyCount > 0 ? "\n\n🔴 WARNING: \(riskyCount) risky cache(s) selected — may contain data that cannot be rebuilt." : ""
            let xcodeWarning = diskMonitor.isXcodeRunning()
                ? "\n\n⚠️ Xcode is currently running! Close Xcode first for best results."
                : ""
            Text("Clean \(toClean.count) selected cache(s)?\nThis will move \(formatBytes(totalSize)) to Trash.\n\nFiles go to Trash — you can recover them.\(riskyNote)\(xcodeWarning)")
        }
    }
    
    // MARK: - Main Screen
    var mainScreen: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                headerView
                
                Divider()
                
                // Permission warnings (if any)
                if diskMonitor.notificationPermission == .denied {
                    permissionBanner
                    Divider()
                }
                
                // Cleanable summary card (only when there's stuff to clean)
                let artifactTotal = diskMonitor.projectArtifacts.reduce(Int64(0)) { $0 + $1.size }
                if diskMonitor.safeCleanable > 10_485_760 || diskMonitor.riskyCleanable > 10_485_760 || artifactTotal > 10_485_760 {
                    cleanableSummary
                    Divider()
                }
                
                // Tab bar
                tabBar
                
                Divider()
                
                // Content
                ScrollView {
                    switch selectedTab {
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
            
            // Onboarding overlay (first launch)
            if diskMonitor.isFirstLaunch && !diskMonitor.hasCompletedFirstScan {
                onboardingView
            }
        }
    }
    
    // MARK: - Cleanable Summary (Hero Card)
    var cleanableSummary: some View {
        let safeDevTotal = diskMonitor.devCaches.filter { $0.riskLevel != "risky" }.reduce(Int64(0)) { $0 + $1.size }
        let riskyDevTotal = diskMonitor.devCaches.filter { $0.riskLevel == "risky" }.reduce(Int64(0)) { $0 + $1.size }
        let artifactTotal = diskMonitor.projectArtifacts.reduce(Int64(0)) { $0 + $1.size }
        let trashTotal = diskMonitor.trashSize()
        let grandTotal = safeDevTotal + riskyDevTotal + artifactTotal + trashTotal
        
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
                            Image(systemName: "folder.badge.minus")
                                .font(.system(size: 10))
                            Text("Clean Projects")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color.cyan.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.cyan)
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
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
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
            // Recovered banner
            if diskMonitor.showRecoveredBanner && diskMonitor.lastCleanedAmount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                    Text("Recovered \(formatBytes(diskMonitor.lastCleanedAmount))!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
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
            let trash = diskMonitor.trashSize()
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
                        diskMonitor.emptyTrash()
                    }
                    .font(.system(size: 10))
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
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
    
    // MARK: - Developer Tab
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
                
                ForEach(diskMonitor.devCaches) { cache in
                    devCacheRow(cache)
                }
            }
        }
        .padding(.vertical, 4)
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
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
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
                    Text("No stale project artifacts found")
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
                            Text("Project Build Artifacts")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(diskMonitor.projectArtifacts.count) found · \(staleCount) stale (>30 days)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(formatBytes(totalArtifacts))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
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
                    showCleanArtifactConfirm = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .help("Clean \(artifact.artifactName)")
                
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
        VStack(spacing: 2) {
            if diskMonitor.largeFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.clock")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No files larger than 100 MB found")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Scanning Downloads, Documents, Desktop, Movies")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
            } else {
                ForEach(diskMonitor.largeFiles) { file in
                    largeFileRow(file)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    func largeFileRow(_ file: LargeFile) -> some View {
        HStack {
            Image(systemName: fileIcon(for: file.name))
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
            Button(action: {
                diskMonitor.revealInFinder(file.path)
            }) {
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
    
    func fileIcon(for name: String) -> String {
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
                    onboardingFeature(icon: "trash", text: "Safely moves files to Trash (always recoverable)")
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
        let cachesToShow = cacheCleanMode == .safe
            ? diskMonitor.devCaches.filter { $0.riskLevel != "risky" }
            : diskMonitor.devCaches
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
                    Text("Safe Only")
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
                    cacheCleanMode = .all
                    selectedCacheIDs = []
                }) {
                    Text("All")
                        .font(.system(size: 10, weight: cacheCleanMode == .all ? .semibold : .regular))
                        .foregroundColor(cacheCleanMode == .all ? .red : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(cacheCleanMode == .all ? Color.red.opacity(0.1) : Color.clear)
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
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(cache.cacheDescription)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(formatBytes(cache.size))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(isSelected ? Color.accentColor.opacity(0.04) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Risky warning (only in All mode)
                        if cacheCleanMode == .all {
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
                showCleanSelectedCachesConfirm = true
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
                .background(selectedCount > 0 && !isCleaning ? Color.green : Color.gray.opacity(0.3))
                .foregroundColor(selectedCount > 0 && !isCleaning ? .white : .secondary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0 || isCleaning)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
        .frame(width: 380, height: 540)
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
                Text("Clean Projects")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Back__")
                    .font(.system(size: 12))
                    .hidden()
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
                                        .font(.system(size: 12))
                                        .frame(width: 18)
                                        .foregroundColor(artifact.isStale ? .orange : .purple)
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(artifact.projectName)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.primary)
                                            Text(artifact.artifactName)
                                                .font(.system(size: 8))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 3)
                                                .padding(.vertical, 1)
                                                .background(RoundedRectangle(cornerRadius: 2).fill(Color.purple.opacity(0.5)))
                                            if let days = artifact.daysSinceModified, days > 30 {
                                                Text("\(days)d")
                                                    .font(.system(size: 8))
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        Text(artifact.projectType)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(formatBytes(artifact.size))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
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
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12))
                    }
                    Text(isCleaning ? "Removing..." : "Remove Selected (\(formatBytes(selectedSize)))")
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
        .frame(width: 380, height: 540)
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
            if diskMonitor.totalSavedAllTime > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                    Text("Total saved: \(formatBytes(diskMonitor.totalSavedAllTime))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                }
            } else {
                Text("ClearDisk v1.6.1")
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
