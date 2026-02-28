import SwiftUI

// MARK: - Main View
struct MainView: View {
    @ObservedObject var diskMonitor: DiskMonitor
    @State private var selectedTab: Tab = .overview
    @State private var showCleanConfirm = false
    @State private var showCleanAllConfirm = false
    @State private var cacheToClean: DevCache?
    
    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case developer = "Developer"
        case largeFiles = "Large Files"
    }
    
    var body: some View {
        ZStack {
            // Main app view
            VStack(spacing: 0) {
                // Header
                headerView
                
                Divider()
                
                // Permission warnings (if any)
                if !diskMonitor.inaccessiblePaths.isEmpty || diskMonitor.notificationPermission == .denied {
                    permissionBanner
                    Divider()
                }
                
                // Cleanable summary card (only when there's stuff to clean)
                if diskMonitor.totalCleanable > 10_485_760 { // > 10MB
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
        .frame(width: 380, height: 540)
        .alert("Clean Cache", isPresented: $showCleanConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let cache = cacheToClean {
                    diskMonitor.cleanDevCache(cache)
                }
            }
        } message: {
            if let cache = cacheToClean {
                Text("Delete all contents of \(cache.name)?\nThis will move \(formatBytes(cache.size)) to Trash.\n\n\(cache.riskEmoji) \(cache.riskDescription)")
            }
        }
        .alert("Clean All Developer Caches", isPresented: $showCleanAllConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                diskMonitor.cleanAllDevCaches()
            }
        } message: {
            let total = diskMonitor.devCaches.reduce(Int64(0)) { $0 + $1.size }
            let riskyCount = diskMonitor.devCaches.filter { $0.riskLevel == "risky" }.count
            let riskyNote = riskyCount > 0 ? "\n\n🔴 \(riskyCount) risky cache(s) included — may contain data that cannot be rebuilt." : ""
            Text("Move ALL developer caches to Trash?\nThis will free \(formatBytes(total)).\n\n\(diskMonitor.devCaches.count) cache locations will be cleaned.\nFiles go to Trash — you can recover them.\(riskyNote)")
        }
    }
    
    // MARK: - Cleanable Summary
    var cleanableSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(formatBytes(diskMonitor.totalCleanable)) cleanable")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                let devTotal = diskMonitor.devCaches.reduce(Int64(0)) { $0 + $1.size }
                let trashTotal = diskMonitor.trashSize()
                var parts: [String] = []
                let _ = {
                    if devTotal > 0 { parts.append("\(formatBytes(devTotal)) dev caches") }
                    if trashTotal > 0 { parts.append("\(formatBytes(trashTotal)) trash") }
                }()
                if !parts.isEmpty {
                    Text(parts.joined(separator: " + "))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.06))
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
        VStack(spacing: 2) {
            ForEach(diskMonitor.categories) { cat in
                categoryRow(cat)
            }
            
            // Trash
            let trash = diskMonitor.trashSize()
            if trash > 0 {
                HStack {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                        .frame(width: 24)
                        .foregroundColor(.orange)
                    Text("Trash")
                        .font(.system(size: 13))
                    Spacer()
                    Text(formatBytes(trash))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button("Empty") {
                        diskMonitor.emptyTrash()
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }
    
    func categoryRow(_ cat: DiskCategory) -> some View {
        HStack {
            Image(systemName: cat.icon)
                .font(.system(size: 14))
                .frame(width: 24)
                .foregroundColor(.accentColor)
            Text(cat.name)
                .font(.system(size: 13))
            Spacer()
            Text(formatBytes(cat.size))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                        Text("Total Developer Cache")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(diskMonitor.devCaches.count) locations found")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(totalDev))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                    Button(action: {
                        showCleanAllConfirm = true
                    }) {
                        Label("Clean All", systemImage: "trash.fill")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
                    Text(cache.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
            
            if !diskMonitor.inaccessiblePaths.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("\(diskMonitor.inaccessiblePaths.count) path\(diskMonitor.inaccessiblePaths.count == 1 ? "" : "s") not readable — sizes may be incomplete")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.06))
    }
    
    // MARK: - Footer
    var footerView: some View {
        HStack {
            Text("ClearDisk v1.0")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
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
