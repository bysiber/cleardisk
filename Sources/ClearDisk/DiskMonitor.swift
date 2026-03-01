import Foundation
import AppKit
import UserNotifications

// MARK: - Disk Monitor
class DiskMonitor: ObservableObject {
    @Published var totalSpace: Int64 = 0
    @Published var freeSpace: Int64 = 0
    @Published var usedSpace: Int64 = 0
    @Published var usedPercentage: Int = 0
    @Published var categories: [DiskCategory] = []
    @Published var devCaches: [DevCache] = []
    @Published var largeFiles: [LargeFile] = []
    @Published var projectArtifacts: [ProjectArtifact] = [] // stale node_modules, target/, build/ etc.
    @Published var isScanning: Bool = false
    @Published var totalCleanable: Int64 = 0
    @Published var safeCleanable: Int64 = 0 // only safe + caution caches + trash
    @Published var riskyCleanable: Int64 = 0 // risky caches (e.g. Docker data)
    @Published var forecastDaysUntilFull: Int? = nil // nil = not enough data
    @Published var dailyGrowthRate: Int64 = 0 // bytes per day
    
    // Savings tracking
    @Published var totalSavedAllTime: Int64 = 0 // cumulative bytes cleaned
    @Published var lastCleanedAmount: Int64 = 0 // last cleanup size (for "Recovered X!" banner)
    @Published var showRecoveredBanner: Bool = false // transient banner after cleanup
    private let savedKey = "ClearDisk.totalSaved"
    
    // Permission & access status
    @Published var notificationPermission: PermissionState = .unknown
    @Published var inaccessiblePaths: [String] = [] // paths that couldn't be read
    @Published var scanErrors: [String] = [] // non-fatal errors during scan
    @Published var hasCompletedFirstScan: Bool = false
    
    // Track notification state to avoid spam
    private var lastNotifiedThreshold: Int = 0
    
    // Storage history key
    private let historyKey = "ClearDisk.usageHistory"
    
    // Onboarding key
    private let onboardingKey = "ClearDisk.onboardingComplete"
    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: onboardingKey)
    }
    func markOnboardingComplete() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }
    
    func loadSavedTotal() {
        totalSavedAllTime = Int64(UserDefaults.standard.integer(forKey: savedKey))
    }
    
    private func addToSavings(_ bytes: Int64) {
        totalSavedAllTime += bytes
        lastCleanedAmount = bytes
        showRecoveredBanner = true
        UserDefaults.standard.set(Int(totalSavedAllTime), forKey: savedKey)
        
        // Auto-hide banner after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.showRecoveredBanner = false
        }
    }
    
    // Whether we're running inside a proper .app bundle (needed for UNUserNotificationCenter)
    private var isInAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil
    }
    
    func setupNotifications() {
        guard isInAppBundle else {
            print("⚠️ Not in .app bundle — notifications disabled (use build_app.sh or open ClearDisk.app)")
            notificationPermission = .denied
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Notification auth error: \(error)")
                    self?.notificationPermission = .denied
                } else {
                    self?.notificationPermission = granted ? .granted : .denied
                }
            }
        }
    }
    
    /// Check current notification permission status (without prompting)
    func checkNotificationStatus() {
        guard isInAppBundle else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self?.notificationPermission = .granted
                case .denied:
                    self?.notificationPermission = .denied
                case .notDetermined:
                    self?.notificationPermission = .unknown
                @unknown default:
                    self?.notificationPermission = .unknown
                }
            }
        }
    }
    
    /// Check if a path is readable before scanning
    private func canAccess(path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }
    
    private var isScanInProgress = false
    
    func scan() {
        guard !isScanInProgress else { return } // Prevent concurrent scans
        isScanInProgress = true
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Reset scan status
            let errors: [String] = []
            var inaccessible: [String] = []
            
            self?.scanDiskSpace()
            self?.scanDevCaches()
            self?.scanLargeFiles()
            self?.scanProjectArtifacts()
            
            // Check which dev cache paths are inaccessible
            let devPaths = self?.devCachePaths() ?? []
            for (name, path) in devPaths {
                let expanded = (path as NSString).expandingTildeInPath
                let parent = (expanded as NSString).deletingLastPathComponent
                if FileManager.default.fileExists(atPath: parent) && !(self?.canAccess(path: expanded) ?? true) {
                    inaccessible.append(name)
                }
            }
            
            DispatchQueue.main.async {
                self?.isScanning = false
                self?.isScanInProgress = false
                self?.inaccessiblePaths = inaccessible
                self?.scanErrors = errors
                self?.hasCompletedFirstScan = true
                self?.calculateCleanable()
                self?.recordUsageSnapshot()
                self?.calculateForecast()
                self?.checkThresholdNotification()
                self?.checkNotificationStatus()
            }
        }
    }
    
    private func calculateCleanable() {
        let devTotal = devCaches.reduce(Int64(0)) { $0 + $1.size }
        let safeDevTotal = devCaches.filter { $0.riskLevel != "risky" }.reduce(Int64(0)) { $0 + $1.size }
        let riskyDevTotal = devCaches.filter { $0.riskLevel == "risky" }.reduce(Int64(0)) { $0 + $1.size }
        let trashTotal = trashSize()
        totalCleanable = devTotal + trashTotal
        safeCleanable = safeDevTotal + trashTotal
        riskyCleanable = riskyDevTotal
    }
    
    // MARK: - Storage Forecast
    private func recordUsageSnapshot() {
        let now = Date().timeIntervalSince1970
        var history = loadHistory()
        
        // Only record if last snapshot is at least 1 hour old
        if let last = history.last, now - last.timestamp < 3600 {
            return
        }
        
        history.append(UsageSnapshot(timestamp: now, usedBytes: usedSpace))
        
        // Keep max 90 days of data (one snapshot per hour max = ~2160 entries)
        let ninetyDaysAgo = now - 90 * 86400
        history = history.filter { $0.timestamp > ninetyDaysAgo }
        
        saveHistory(history)
    }
    
    private func calculateForecast() {
        let history = loadHistory()
        
        // Need at least 2 days of data spread across at least 24 hours
        guard history.count >= 2 else {
            forecastDaysUntilFull = nil
            dailyGrowthRate = 0
            return
        }
        
        let first = history.first!
        let last = history.last!
        let timeSpanDays = (last.timestamp - first.timestamp) / 86400.0
        
        guard timeSpanDays >= 1.0 else {
            forecastDaysUntilFull = nil
            dailyGrowthRate = 0
            return
        }
        
        // Simple linear regression: bytes per day
        let bytesGrown = last.usedBytes - first.usedBytes
        let rate = Double(bytesGrown) / timeSpanDays
        dailyGrowthRate = Int64(rate)
        
        if rate <= 0 {
            // Disk usage is shrinking or stable
            forecastDaysUntilFull = nil
            return
        }
        
        let remaining = totalSpace - usedSpace
        let daysLeft = Double(remaining) / rate
        
        if daysLeft > 365 {
            forecastDaysUntilFull = nil // More than a year = don't worry
        } else {
            forecastDaysUntilFull = max(1, Int(daysLeft))
        }
    }
    
    // MARK: - History Persistence
    private func loadHistory() -> [UsageSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let history = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else {
            return []
        }
        return history
    }
    
    private func saveHistory(_ history: [UsageSnapshot]) {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
    
    var historyDataPointCount: Int {
        loadHistory().count
    }
    
    var historySpanDays: Int {
        let history = loadHistory()
        guard history.count >= 2 else { return 0 }
        let span = (history.last!.timestamp - history.first!.timestamp) / 86400.0
        return max(0, Int(span))
    }
    
    private func checkThresholdNotification() {
        let pct = usedPercentage
        if pct >= 90 && lastNotifiedThreshold < 90 {
            sendNotification(
                title: "⚠️ Disk Almost Full!",
                body: "Disk \(pct)% full. \(formatBytes(safeCleanable)) can be safely cleaned with ClearDisk."
            )
            lastNotifiedThreshold = 90
        } else if pct >= 80 && lastNotifiedThreshold < 80 {
            sendNotification(
                title: "Disk Space Low",
                body: "Disk \(pct)% full. \(formatBytes(safeCleanable)) of developer caches can be safely cleaned."
            )
            lastNotifiedThreshold = 80
        }
        // Reset if usage drops below threshold
        if pct < 75 {
            lastNotifiedThreshold = 0
        }
    }
    
    private func sendNotification(title: String, body: String) {
        guard isInAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Disk Space
    private func scanDiskSpace() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let used = total - free
            
            DispatchQueue.main.async { [weak self] in
                self?.totalSpace = total
                self?.freeSpace = free
                self?.usedSpace = used
                self?.usedPercentage = total > 0 ? Int((Double(used) / Double(total)) * 100) : 0
            }
        } catch {
            print("Error getting disk space: \(error)")
        }
        
        // Scan categories
        let home = homeDir.path
        let categoryPaths: [(String, String, [String])] = [
            ("Applications", "app.fill", ["/Applications", "\(home)/Applications"]),
            ("Documents", "doc.fill", ["\(home)/Documents"]),
            ("Downloads", "arrow.down.circle.fill", ["\(home)/Downloads"]),
            ("Desktop", "menubar.dock.rectangle", ["\(home)/Desktop"]),
            ("Developer", "hammer.fill", [
                "\(home)/Library/Developer",
                "\(home)/Developer",
            ]),
            ("Caches", "internaldrive.fill", [
                "\(home)/Library/Caches",
                "/Library/Caches",
            ]),
            ("Mail", "envelope.fill", ["\(home)/Library/Mail"]),
            ("Music", "music.note", ["\(home)/Music"]),
            ("Movies", "film.fill", ["\(home)/Movies"]),
            ("Photos", "photo.fill", ["\(home)/Pictures"]),
        ]
        
        var cats: [DiskCategory] = []
        for (name, icon, paths) in categoryPaths {
            var totalSize: Int64 = 0
            for path in paths {
                totalSize += directorySize(path: path)
            }
            if totalSize > 0 {
                cats.append(DiskCategory(name: name, icon: icon, size: totalSize))
            }
        }
        
        cats.sort { $0.size > $1.size }
        
        DispatchQueue.main.async { [weak self] in
            self?.categories = cats
        }
    }
    
    // MARK: - Developer Caches
    
    /// Human-readable descriptions for each cache type (inspired by npkill's descriptions)
    static let cacheDescriptions: [String: String] = [
        "Xcode DerivedData": "Build products, indexes, and logs. Rebuilds automatically when you open a project.",
        "Xcode Archives": "Archived builds for App Store or distribution. Re-archive from Xcode to recreate.",
        "Xcode Simulators": "iOS/watchOS/tvOS simulator devices and data. Re-download from Xcode → Settings.",
        "Xcode Caches": "Internal Xcode product caches. Rebuilds automatically on next build.",
        "Xcode Device Support": "Debug symbols for connected iPhones/iPads. Re-downloads when device connects.",
        "Xcode Logs": "Simulator crash reports and diagnostic logs. Safe to remove anytime.",
        "Xcode Previews": "SwiftUI preview simulator data. Rebuilds automatically on next preview.",
        "Simulator Caches": "CoreSimulator dyld and framework caches. Rebuilds automatically.",
        "Swift PM Cache": "Downloaded Swift packages. Re-downloads on next build (swift build).",
        "CocoaPods Cache": "Downloaded pod specs and sources. Re-downloads on pod install.",
        "Carthage": "Carthage dependency build cache. Re-downloads on carthage update.",
        "Homebrew Cache": "Downloaded formula bottles and taps. Re-downloads on brew install.",
        "npm Cache": "Cached package tarballs from npmjs.org. Re-downloads on npm install.",
        "Yarn Cache": "Cached Yarn packages. Re-downloads on yarn install.",
        "pnpm Store": "Content-addressable package store. Re-downloads on pnpm install.",
        "Bun Cache": "Cached Bun packages. Re-downloads on bun install.",
        "pip Cache": "Downloaded Python wheels and sdists. Re-downloads on pip install.",
        "Conda Packages": "Cached Conda environments and packages. Re-downloads on conda install.",
        "Gradle Cache": "Downloaded JARs, build outputs, and wrapper dists. Re-downloads on gradle build.",
        "Maven Cache": "Local Maven repository (.m2). Re-downloads on mvn build.",
        "Android Emulators": "Android Virtual Devices and disk images. Must re-create in AVD Manager.",
        "Docker (Data)": "Docker images, containers, and volumes. May lose running containers and uncommitted data!",
        "Composer Cache": "Cached PHP packages. Re-downloads on composer install.",
        "Go Modules": "Go module download cache. Re-downloads on go mod download.",
        "Rust Cargo": "Cached crate sources and registries. Re-downloads on cargo build.",
        "Flutter/Pub Cache": "Cached Dart/Flutter packages. Re-downloads on flutter pub get.",
        "JetBrains Cache": "IDE caches (IntelliJ, WebStorm, etc). Rebuilds on IDE restart.",
        "Ruby Gems": "Installed Ruby gems and documentation. Re-install with bundle install.",
    ]
    
    /// Resolve DerivedData subfolders to project names using info.plist → WorkspacePath
    func derivedDataProjectSummary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ddPath = "\(home)/Library/Developer/Xcode/DerivedData"
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(atPath: ddPath) else { return nil }
        
        var projects: [(String, Int64)] = []
        for item in contents {
            if item == "ModuleCache.noindex" || item.hasPrefix(".") { continue }
            let fullPath = (ddPath as NSString).appendingPathComponent(item)
            
            // Try reading info.plist for workspace path
            let plistPath = (fullPath as NSString).appendingPathComponent("info.plist")
            var projectName: String? = nil
            if let plistData = fm.contents(atPath: plistPath),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               let workspacePath = plist["WorkspacePath"] as? String {
                projectName = ((workspacePath as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            
            let name = projectName ?? item.components(separatedBy: "-").dropLast().joined(separator: "-")
            if name.isEmpty { continue }
            
            let size = directorySize(path: fullPath)
            if size > 1_048_576 { // > 1 MB
                projects.append((name, size))
            }
        }
        
        guard !projects.isEmpty else { return nil }
        
        projects.sort { $0.1 > $1.1 }
        let top = projects.prefix(5)
        let lines = top.map { "\($0.0): \(formatBytes($0.1))" }
        var result = lines.joined(separator: ", ")
        if projects.count > 5 {
            result += " +\(projects.count - 5) more"
        }
        return result
    }
    
    /// Check if Xcode is currently running (to warn before cleaning DerivedData)
    func isXcodeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" }
    }
    
    /// Returns list of (name, path) tuples for all known dev cache paths
    func devCachePaths() -> [(String, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            // Xcode & Apple
            ("Xcode DerivedData", "\(home)/Library/Developer/Xcode/DerivedData"),
            ("Xcode Archives", "\(home)/Library/Developer/Xcode/Archives"),
            ("Xcode Simulators", "\(home)/Library/Developer/CoreSimulator/Devices"),
            ("Xcode Caches", "\(home)/Library/Developer/Xcode/Products"),
            ("Xcode Device Support", "\(home)/Library/Developer/Xcode/iOS DeviceSupport"),
            ("Xcode Logs", "\(home)/Library/Logs/CoreSimulator"),
            ("Xcode Previews", "\(home)/Library/Developer/Xcode/UserData/Previews"),
            ("Simulator Caches", "\(home)/Library/Developer/CoreSimulator/Caches"),
            ("Swift PM Cache", "\(home)/Library/Caches/org.swift.swiftpm"),
            // iOS/macOS Ecosystem
            ("CocoaPods Cache", "\(home)/Library/Caches/CocoaPods"),
            ("Carthage", "\(home)/Library/Caches/org.carthage.CarthageKit"),
            // System Tools
            ("Homebrew Cache", "\(home)/Library/Caches/Homebrew"),
            // JavaScript/Node
            ("npm Cache", "\(home)/.npm/_cacache"),
            ("Yarn Cache", "\(home)/Library/Caches/Yarn"),
            ("pnpm Store", "\(home)/Library/pnpm/store"),
            ("Bun Cache", "\(home)/.bun/install/cache"),
            // Python
            ("pip Cache", "\(home)/Library/Caches/pip"),
            ("Conda Packages", "\(home)/.conda/pkgs"),
            // Java/Android
            ("Gradle Cache", "\(home)/.gradle/caches"),
            ("Maven Cache", "\(home)/.m2/repository"),
            ("Android Emulators", "\(home)/.android/avd"),
            // Containers
            ("Docker (Data)", "\(home)/Library/Containers/com.docker.docker/Data"),
            // PHP
            ("Composer Cache", "\(home)/.composer/cache"),
            // Go/Rust
            ("Go Modules", "\(home)/go/pkg/mod/cache"),
            ("Rust Cargo", "\(home)/.cargo/registry"),
            // Mobile
            ("Flutter/Pub Cache", "\(home)/.pub-cache"),
            // IDEs
            ("JetBrains Cache", "\(home)/.cache/JetBrains"),
            // Ruby
            ("Ruby Gems", "\(home)/.gem"),
        ]
    }
    
    private func scanDevCaches() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        // Risk levels: safe = rebuild with command, caution = may need re-download, risky = data loss possible
        // (name, icon, path, riskLevel)
        let devPaths: [(String, String, String, String)] = [
            // Xcode & Apple
            ("Xcode DerivedData", "xmark.bin.fill", "\(home)/Library/Developer/Xcode/DerivedData", "safe"),
            ("Xcode Archives", "archivebox.fill", "\(home)/Library/Developer/Xcode/Archives", "caution"),
            ("Xcode Simulators", "iphone", "\(home)/Library/Developer/CoreSimulator/Devices", "caution"),
            ("Xcode Caches", "internaldrive", "\(home)/Library/Developer/Xcode/Products", "safe"),
            ("Xcode Device Support", "cpu", "\(home)/Library/Developer/Xcode/iOS DeviceSupport", "safe"),
            ("Xcode Logs", "doc.text.fill", "\(home)/Library/Logs/CoreSimulator", "safe"),
            ("Xcode Previews", "eye.fill", "\(home)/Library/Developer/Xcode/UserData/Previews", "safe"),
            ("Simulator Caches", "internaldrive.fill", "\(home)/Library/Developer/CoreSimulator/Caches", "safe"),
            ("Swift PM Cache", "swift", "\(home)/Library/Caches/org.swift.swiftpm", "safe"),
            // iOS/macOS Ecosystem
            ("CocoaPods Cache", "shippingbox.fill", "\(home)/Library/Caches/CocoaPods", "safe"),
            ("Carthage", "cart.fill", "\(home)/Library/Caches/org.carthage.CarthageKit", "safe"),
            // System Tools
            ("Homebrew Cache", "mug.fill", "\(home)/Library/Caches/Homebrew", "safe"),
            // JavaScript/Node
            ("npm Cache", "shippingbox", "\(home)/.npm/_cacache", "safe"),
            ("Yarn Cache", "figure.walk", "\(home)/Library/Caches/Yarn", "safe"),
            ("pnpm Store", "shippingbox.and.arrow.backward.fill", "\(home)/Library/pnpm/store", "safe"),
            ("Bun Cache", "hare.fill", "\(home)/.bun/install/cache", "safe"),
            // Python
            ("pip Cache", "cube.fill", "\(home)/Library/Caches/pip", "safe"),
            ("Conda Packages", "flask.fill", "\(home)/.conda/pkgs", "safe"),
            // Java/Android
            ("Gradle Cache", "gearshape.fill", "\(home)/.gradle/caches", "safe"),
            ("Maven Cache", "building.columns.fill", "\(home)/.m2/repository", "safe"),
            ("Android Emulators", "apps.iphone", "\(home)/.android/avd", "caution"),
            // Containers
            ("Docker (Data)", "cube.transparent", "\(home)/Library/Containers/com.docker.docker/Data", "risky"),
            // PHP
            ("Composer Cache", "music.note.list", "\(home)/.composer/cache", "safe"),
            // Go/Rust
            ("Go Modules", "leaf.fill", "\(home)/go/pkg/mod/cache", "safe"),
            ("Rust Cargo", "wrench.fill", "\(home)/.cargo/registry", "safe"),
            // Mobile
            ("Flutter/Pub Cache", "bird.fill", "\(home)/.pub-cache", "safe"),
            // IDEs
            ("JetBrains Cache", "laptopcomputer", "\(home)/.cache/JetBrains", "safe"),
            // Ruby
            ("Ruby Gems", "diamond.fill", "\(home)/.gem", "safe"),
        ]
        
        var caches: [DevCache] = []
        for (name, icon, path, riskLevel) in devPaths {
            let size = directorySize(path: path)
            if size > 1_048_576 { // Only show if > 1MB
                let lastAccessed = lastAccessDate(path: path)
                let daysSinceAccess = daysSince(lastAccessed)
                let suggestion = generateSuggestion(name: name, size: size, daysSinceAccess: daysSinceAccess)
                let desc = DiskMonitor.cacheDescriptions[name] ?? ""
                
                // Resolve DerivedData subfolders to project names
                var detail: String? = nil
                if name == "Xcode DerivedData" {
                    detail = derivedDataProjectSummary()
                }
                
                caches.append(DevCache(
                    name: name,
                    icon: icon,
                    path: path,
                    size: size,
                    lastAccessed: lastAccessed,
                    daysSinceAccess: daysSinceAccess,
                    suggestion: suggestion,
                    riskLevel: riskLevel,
                    cacheDescription: desc,
                    detail: detail
                ))
            }
        }
        
        caches.sort { $0.size > $1.size }
        
        DispatchQueue.main.async { [weak self] in
            self?.devCaches = caches
        }
    }
    
    private func lastAccessDate(path: String) -> Date? {
        let fm = FileManager.default
        // Check modification date of the directory itself or its most recent child
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
    
    private func daysSince(_ date: Date?) -> Int? {
        guard let date = date else { return nil }
        let interval = Date().timeIntervalSince(date)
        return max(0, Int(interval / 86400))
    }
    
    private func generateSuggestion(name: String, size: Int64, daysSinceAccess: Int?) -> String? {
        // Generate smart suggestion based on age and size
        guard let days = daysSinceAccess else { return nil }
        
        let sizeGB = Double(size) / 1_073_741_824
        
        if days > 90 && sizeGB >= 1.0 {
            return "⚠️ Not used for \(days) days, \(formatBytes(size)) — safe to clean"
        } else if days > 60 {
            return "💡 Unused for \(days) days — consider cleaning"
        } else if days > 30 && sizeGB >= 5.0 {
            return "💡 \(days) days old, large at \(formatBytes(size))"
        }
        return nil
    }
    
    // MARK: - Large Files
    private func scanLargeFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let threshold: Int64 = 100_000_000 // 100MB
        var files: [LargeFile] = []
        
        let scanDirs = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Movies",
        ]
        
        for dir in scanDirs {
            findLargeFiles(in: dir, threshold: threshold, results: &files, maxDepth: 3, currentDepth: 0)
        }
        
        files.sort { $0.size > $1.size }
        
        DispatchQueue.main.async { [weak self] in
            self?.largeFiles = Array(files.prefix(20))
        }
    }
    
    private func findLargeFiles(in path: String, threshold: Int64, results: inout [LargeFile], maxDepth: Int, currentDepth: Int) {
        guard currentDepth < maxDepth else { return }
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        
        for item in contents {
            if item.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(item)
            
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            
            if isDir.boolValue {
                findLargeFiles(in: fullPath, threshold: threshold, results: &results, maxDepth: maxDepth, currentDepth: currentDepth + 1)
            } else {
                // Use allocatedSize for accurate reporting (consistent with directorySize)
                if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                   let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize,
                   Int64(size) >= threshold {
                    results.append(LargeFile(
                        name: item,
                        path: fullPath,
                        size: Int64(size)
                    ))
                }
            }
        }
    }
    
    // MARK: - Cleanup Actions
    
    /// Move items to Trash instead of permanent delete — user can recover for 30 days
    /// NEVER falls back to permanent delete. If trash fails, it fails safely.
    private func moveToTrash(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            print("trashItem failed for \(path): \(error) — NOT deleting permanently (safe delete policy)")
            return false
        }
    }
    
    func cleanDevCache(_ cache: DevCache) {
        let savedSize = cache.size
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(atPath: cache.path) {
                for item in contents {
                    let fullPath = (cache.path as NSString).appendingPathComponent(item)
                    _ = self?.moveToTrash(path: fullPath)
                }
            }
            DispatchQueue.main.async {
                self?.addToSavings(savedSize)
                self?.scan()
            }
        }
    }
    
    /// Clean only safe caches (excludes risky caches like Docker)
    func cleanSafeCaches() {
        let safeCaches = devCaches.filter { $0.riskLevel != "risky" }
        let totalSize = safeCaches.reduce(Int64(0)) { $0 + $1.size }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for cache in safeCaches {
                let fm = FileManager.default
                if let contents = try? fm.contentsOfDirectory(atPath: cache.path) {
                    for item in contents {
                        let fullPath = (cache.path as NSString).appendingPathComponent(item)
                        _ = self?.moveToTrash(path: fullPath)
                    }
                }
            }
            DispatchQueue.main.async {
                self?.addToSavings(totalSize)
                self?.scan()
            }
        }
    }
    
    /// Clean ALL caches including risky ones (requires explicit user confirmation)
    func cleanAllDevCaches() {
        let totalSize = devCaches.reduce(Int64(0)) { $0 + $1.size }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let caches = self?.devCaches else { return }
            for cache in caches {
                let fm = FileManager.default
                if let contents = try? fm.contentsOfDirectory(atPath: cache.path) {
                    for item in contents {
                        let fullPath = (cache.path as NSString).appendingPathComponent(item)
                        _ = self?.moveToTrash(path: fullPath)
                    }
                }
            }
            DispatchQueue.main.async {
                self?.addToSavings(totalSize)
                self?.scan()
            }
        }
    }
    
    func emptyTrash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        let savedSize = trashSize()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(atPath: trashPath) {
                for item in contents {
                    let fullPath = (trashPath as NSString).appendingPathComponent(item)
                    try? fm.removeItem(atPath: fullPath) // Trash empty = permanent delete (intended)
                }
            }
            DispatchQueue.main.async {
                self?.addToSavings(savedSize)
                self?.scan()
            }
        }
    }
    
    func trashSize() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directorySize(path: "\(home)/.Trash")
    }
    
    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
    
    // MARK: - Project Artifact Scanner (inspired by kondo/npkill)
    
    /// Known project types: (marker file, artifact directory name, project type label)
    static let projectTypes: [(marker: String, artifact: String, label: String)] = [
        ("package.json", "node_modules", "Node.js"),
        ("Cargo.toml", "target", "Rust"),
        ("Package.swift", ".build", "Swift PM"),
        ("go.mod", "vendor", "Go"),
        ("build.gradle", "build", "Gradle"),
        ("build.gradle.kts", "build", "Gradle (Kotlin)"),
        ("pom.xml", "target", "Maven"),
        ("composer.json", "vendor", "PHP/Composer"),
        ("Gemfile", "vendor/bundle", "Ruby"),
        ("pubspec.yaml", ".dart_tool", "Flutter/Dart"),
        ("CMakeLists.txt", "build", "CMake"),
    ]
    
    /// Directories to scan for projects
    private func projectScanRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Documents",
            "\(home)/Developer",
            "\(home)/Projects",
            "\(home)/Code",
            "\(home)/repos",
            "\(home)/src",
            "\(home)/workspace",
            "\(home)/Desktop",
        ]
    }
    
    private func scanProjectArtifacts() {
        var artifacts: [ProjectArtifact] = []
        let fm = FileManager.default
        
        for root in projectScanRoots() {
            guard fm.fileExists(atPath: root) else { continue }
            findProjectArtifacts(in: root, results: &artifacts, maxDepth: 5, currentDepth: 0)
        }
        
        // Sort by size: biggest first (user can change sort in UI)
        artifacts.sort { $0.size > $1.size }
        
        DispatchQueue.main.async { [weak self] in
            self?.projectArtifacts = Array(artifacts.prefix(50)) // top 50 biggest
        }
    }
    
    private func findProjectArtifacts(in path: String, results: inout [ProjectArtifact], maxDepth: Int, currentDepth: Int) {
        guard currentDepth < maxDepth else { return }
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        
        // Check if this directory IS a project root (has a marker file)
        for pt in DiskMonitor.projectTypes {
            let markerPath = (path as NSString).appendingPathComponent(pt.marker)
            let artifactPath = (path as NSString).appendingPathComponent(pt.artifact)
            
            if fm.fileExists(atPath: markerPath) && fm.fileExists(atPath: artifactPath) {
                let size = directorySize(path: artifactPath)
                if size > 10_485_760 { // > 10 MB
                    let projectName = (path as NSString).lastPathComponent
                    let lastModified = lastAccessDate(path: artifactPath)
                    let days = daysSince(lastModified)
                    
                    results.append(ProjectArtifact(
                        projectName: projectName,
                        projectPath: path,
                        artifactPath: artifactPath,
                        artifactName: pt.artifact,
                        projectType: pt.label,
                        size: size,
                        lastModified: lastModified,
                        daysSinceModified: days
                    ))
                }
                // Don't recurse into artifact directories
                return
            }
        }
        
        // Skip node_modules, .git, etc. when recursing
        let skipDirs: Set<String> = ["node_modules", ".git", "target", ".build", "build", "vendor", ".dart_tool", "Pods", "__pycache__", ".venv", "venv"]
        
        for item in contents {
            if item.hasPrefix(".") && item != ".build" { continue }
            if skipDirs.contains(item) { continue }
            
            let fullPath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                findProjectArtifacts(in: fullPath, results: &results, maxDepth: maxDepth, currentDepth: currentDepth + 1)
            }
        }
    }
    
    /// Clean a single project artifact (move to trash)
    func cleanProjectArtifact(_ artifact: ProjectArtifact) {
        let savedSize = artifact.size
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.moveToTrash(path: artifact.artifactPath)
            DispatchQueue.main.async {
                self?.addToSavings(savedSize)
                self?.scan()
            }
        }
    }
    
    // MARK: - Helpers
    func directorySize(path: String) -> Int64 {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [],  // Don't skip hidden files — caches often contain them
            errorHandler: nil
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            // Use totalFileAllocatedSize (accounts for sparse files like Docker.raw)
            // Falls back to fileAllocatedSize if total isn't available
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            totalSize += Int64(size)
        }
        
        return totalSize
    }
}

// MARK: - Permission State
enum PermissionState: String {
    case unknown = "Unknown"
    case granted = "Granted"
    case denied = "Denied"
}

// MARK: - Models
struct DiskCategory: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let size: Int64
}

struct DevCache: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let path: String
    let size: Int64
    let lastAccessed: Date?
    let daysSinceAccess: Int?
    let suggestion: String?
    let riskLevel: String // "safe" = 🟢, "caution" = 🟡, "risky" = 🔴
    let cacheDescription: String // human-readable "what is this?"
    var detail: String? = nil // optional extra detail (e.g. DerivedData project list)
    
    var riskEmoji: String {
        switch riskLevel {
        case "safe": return "🟢"
        case "caution": return "🟡"
        case "risky": return "🔴"
        default: return "⚪"
        }
    }
    
    var riskDescription: String {
        switch riskLevel {
        case "safe": return "Safe — can be rebuilt with a command"
        case "caution": return "Caution — may need large re-download"
        case "risky": return "Risky — may contain irreplaceable data"
        default: return ""
        }
    }
}

struct LargeFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
}

struct ProjectArtifact: Identifiable {
    let id = UUID()
    let projectName: String // e.g. "my-react-app"
    let projectPath: String // full path to project root
    let artifactPath: String // full path to artifact dir (node_modules, target, etc.)
    let artifactName: String // "node_modules", "target", ".build", etc.
    let projectType: String // "Node.js", "Rust", "Swift PM", etc.
    let size: Int64
    let lastModified: Date?
    let daysSinceModified: Int?
    
    var typeIcon: String {
        switch projectType {
        case "Node.js": return "cube.box.fill"
        case "Rust": return "wrench.fill"
        case "Swift PM": return "swift"
        case "Go": return "leaf.fill"
        case "Gradle", "Gradle (Kotlin)": return "gearshape.fill"
        case "Maven": return "building.columns.fill"
        case "PHP/Composer": return "music.note.list"
        case "Ruby": return "diamond.fill"
        case "Flutter/Dart": return "bird.fill"
        case "CMake": return "hammer.fill"
        default: return "folder.fill"
        }
    }
    
    var isStale: Bool {
        guard let days = daysSinceModified else { return false }
        return days > 30
    }
}

struct UsageSnapshot: Codable {
    let timestamp: Double // Unix timestamp
    let usedBytes: Int64
}

// MARK: - Formatting
func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 {
        return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 {
        return String(format: "%.0f MB", mb)
    }
    let kb = Double(bytes) / 1024
    return String(format: "%.0f KB", kb)
}
