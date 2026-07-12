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
    @Published var usageHistory: [UsageSnapshot] = [] // for chart display
    
    // Savings tracking
    @Published var totalSavedAllTime: Int64 = 0 // cumulative bytes cleaned
    @Published var lastCleanedAmount: Int64 = 0 // last cleanup size (for "Recovered X!" banner)
    @Published var showRecoveredBanner: Bool = false // transient banner after cleanup
    private let savedKey = "ClearDisk.totalSaved"
    
    // Per-project cache cleanup history (persisted)
    @Published var projectCleanHistory: [ProjectCleanHistoryEntry] = []
    private let projectHistoryKey = "ClearDisk.projectCleanHistory"
    private let historyMaxEntries = 200
    
    // Permission & access status
    @Published var notificationPermission: PermissionState = .unknown
    @Published var inaccessiblePaths: [String] = [] // paths that couldn't be read
    @Published var hasCompletedFirstScan: Bool = false

    /// Set when a clean could not free the space it promised, so the UI can say so.
    /// Swallowing a failed trash is what let the app report "Recovered X!" while nothing moved.
    @Published var cleanFailure: CleanFailure?
    
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
        loadProjectCleanHistory()
    }
    
    // MARK: - Project Clean History
    func loadProjectCleanHistory() {
        guard let data = UserDefaults.standard.data(forKey: projectHistoryKey) else { return }
        if let decoded = try? JSONDecoder().decode([ProjectCleanHistoryEntry].self, from: data) {
            projectCleanHistory = decoded
        }
    }
    
    private func saveProjectCleanHistory() {
        if let data = try? JSONEncoder().encode(projectCleanHistory) {
            UserDefaults.standard.set(data, forKey: projectHistoryKey)
        }
    }
    
    func appendProjectCleanHistory(_ entry: ProjectCleanHistoryEntry) {
        projectCleanHistory.insert(entry, at: 0)
        if projectCleanHistory.count > historyMaxEntries {
            projectCleanHistory = Array(projectCleanHistory.prefix(historyMaxEntries))
        }
        saveProjectCleanHistory()
    }
    
    func clearProjectCleanHistory() {
        projectCleanHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: projectHistoryKey)
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
        DispatchQueue.main.async { [weak self] in self?.usageHistory = history }
        
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
        "Deno Cache": "Cached Deno modules and compiled scripts. Re-downloads on deno run.",
        "pip Cache": "Downloaded Python wheels and sdists. Re-downloads on pip install.",
        "UV Cache": "Cached Python packages from uv (fast pip alternative). Re-downloads on uv pip install.",
        "Conda Packages": "Cached Conda environments and packages. Re-downloads on conda install.",
        "Poetry Cache": "Cached Poetry dependencies and wheels. Re-downloads on poetry install.",
        "pipenv Virtualenvs": "Pipenv virtual environments. Recreate with pipenv install.",
        "Gradle Cache": "Downloaded JARs, build outputs, and wrapper dists. Re-downloads on gradle build.",
        "Maven Cache": "Local Maven repository (.m2). Re-downloads on mvn build.",
        "Android Emulators": "Android Virtual Devices and disk images. Must re-create in AVD Manager.",
        "Docker (Data)": "Docker images, containers, and volumes. May lose running containers and uncommitted data!",
        "Terraform Plugins": "Terraform/OpenTofu CLI plugins and provider cache. Re-downloads on terraform init.",
        "Composer Cache": "Cached PHP packages. Re-downloads on composer install.",
        "Go Modules": "Go module download cache. Re-downloads on go mod download.",
        "Rust Cargo": "Cached crate sources and registries. Re-downloads on cargo build.",
        "Playwright Browsers": "Downloaded browser binaries for Playwright testing. Re-downloads on npx playwright install.",
        "Puppeteer Browsers": "Downloaded Chromium binaries for Puppeteer. Re-downloads on npx puppeteer install.",
        "Prisma Engines": "Prisma ORM query engine binaries. Re-downloads on npx prisma generate.",
        "Flutter/Pub Cache": "Cached Dart/Flutter packages. Re-downloads on flutter pub get.",
        "JetBrains Cache": "IDE caches (IntelliJ, WebStorm, etc). Rebuilds on IDE restart.",
        "Ruby Gems": "Installed gems and docs. Reinstall with bundle install.",
        "rbenv Versions": "Ruby versions managed by rbenv. Reinstall with rbenv install X.Y.Z.",
        "mise Rubies": "Ruby versions managed by mise. Reinstall with mise install ruby@X.Y.Z.",
        "RVM": "RVM rubies and gemsets. Reinstall with rvm install X.Y.Z.",
        "Bundler Cache": "Downloaded gem files. Rebuilds automatically with bundle install.",
        // AI Tools
        "Claude Desktop": "Claude Desktop conversation cache and temp files. Can grow very large. Re-downloads on next launch.",
        "Claude Code": "Claude Code CLI session history and configs. Re-creates on next session.",
        "HuggingFace Cache": "Downloaded AI/ML models, tokenizers, and datasets. Re-downloads on next use. Large models may take time.",
        "Ollama Models": "Downloaded LLM model files. Re-downloads with ollama pull.",
        "ChatGPT Desktop": "ChatGPT Desktop app data. Conversations sync to cloud.",
        "Cursor Cache": "Cursor editor cache, workspace storage, and extensions data. Re-builds on next launch.",
        "Windsurf Cache": "Windsurf editor cache and workspace data. Re-builds on next launch.",
        // Game Engines
        "Unity Asset Store": "Unity Asset Store downloaded packages. Re-downloads from Unity Package Manager.",
        "UnityHub Templates": "Unity project starter templates downloaded by Unity Hub. Re-download from Hub when needed. Can be 300MB+.",
        "Unity Build Cache": "Unity build artifacts and shader compile cache. Rebuilds automatically on next build.",
        "Unity Logs": "Unity Editor and player log files (crash reports, debug output). Safe to delete anytime.",
        "UnityHub Cache": "Electron/browser cache used by Unity Hub UI. Rebuilds automatically on next launch.",
        "Godot Export Templates": "Godot export templates for each engine version. Re-download from Godot → Export → Manage Export Templates.",
        "Godot Cache": "Godot editor temp and shader cache. Rebuilds automatically on next launch.",
        // Version Managers
        "nvm Node Versions": "Node.js versions managed by nvm. Removing a version uninstalls it — reinstall with nvm install X.Y.Z.",
        "pyenv Versions": "Python versions managed by pyenv. Removing uninstalls that version — reinstall with pyenv install X.Y.Z.",
        "mise Installs": "Language runtimes installed by mise (Node, Python, Ruby, Go, etc.). Removing uninstalls them. Reinstall with mise install.",
        // Extra JVM / Build
        "SBT/Ivy Cache": "Scala/Java dependencies cached by sbt and Ivy. Re-downloads on next sbt compile.",
        "Gradle Wrapper": "Gradle distribution binaries downloaded by wrapper scripts. Re-downloads on next gradle build.",
        "Bazel Cache": "Bazel build and repository caches. Re-populates on next bazel build.",
        // Cloud CLIs
        "AWS CLI Cache": "AWS SSO login tokens and temporary credential cache. Re-generates on next aws sso login.",
        // IDEs (VS Code)
        "VS Code Cache": "VS Code application cache. Safe to delete, rebuilds automatically.",
        "VS Code Data": "VS Code compiled JavaScript cache. Safe to delete, recompiles on launch.",
        "VS Code Extensions Cache": "Downloaded extension VSIX packages. Safe to delete, re-downloads when needed.",
        "VS Code Chromium Cache": "Chromium disk cache used by VS Code. Safe to delete, rebuilds on launch.",
        "VS Code Logs": "Old session logs and telemetry data. Safe to delete anytime.",
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
    
    /// Single source of truth for all developer cache paths
    /// (name, icon, path, riskLevel, group)
    /// Risk levels: safe = rebuild with command, caution = may need re-download, risky = data loss possible
    private func allCachePaths() -> [(name: String, icon: String, path: String, riskLevel: String, group: String?)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            // Xcode & Apple
            ("Xcode DerivedData", "xmark.bin.fill", "\(home)/Library/Developer/Xcode/DerivedData", "safe", "Xcode"),
            ("Xcode Archives", "archivebox.fill", "\(home)/Library/Developer/Xcode/Archives", "caution", "Xcode"),
            ("Xcode Simulators", "iphone", "\(home)/Library/Developer/CoreSimulator/Devices", "caution", "Xcode"),
            ("Xcode Caches", "internaldrive", "\(home)/Library/Developer/Xcode/Products", "safe", "Xcode"),
            ("Xcode Device Support", "cpu", "\(home)/Library/Developer/Xcode/iOS DeviceSupport", "safe", "Xcode"),
            ("Xcode Logs", "doc.text.fill", "\(home)/Library/Logs/CoreSimulator", "safe", "Xcode"),
            ("Xcode Previews", "eye.fill", "\(home)/Library/Developer/Xcode/UserData/Previews", "safe", "Xcode"),
            ("Simulator Caches", "internaldrive.fill", "\(home)/Library/Developer/CoreSimulator/Caches", "safe", "Xcode"),
            ("Swift PM Cache", "swift", "\(home)/Library/Caches/org.swift.swiftpm", "safe", "Xcode"),
            // iOS/macOS Ecosystem
            ("CocoaPods Cache", "shippingbox.fill", "\(home)/Library/Caches/CocoaPods", "safe", nil),
            ("Carthage", "cart.fill", "\(home)/Library/Caches/org.carthage.CarthageKit", "safe", nil),
            // System Tools
            ("Homebrew Cache", "mug.fill", "\(home)/Library/Caches/Homebrew", "safe", nil),
            // JavaScript/Node
            ("npm Cache", "shippingbox", "\(home)/.npm/_cacache", "safe", nil),
            ("Yarn Cache", "figure.walk", "\(home)/Library/Caches/Yarn", "safe", nil),
            ("pnpm Store", "shippingbox.and.arrow.backward.fill", "\(home)/Library/pnpm/store", "safe", nil),
            ("Bun Cache", "hare.fill", "\(home)/.bun/install/cache", "safe", nil),
            ("Deno Cache", "bolt.fill", "\(home)/Library/Caches/deno", "safe", nil),
            // Python
            ("pip Cache", "cube.fill", "\(home)/Library/Caches/pip", "safe", nil),
            ("Conda Packages", "flask.fill", "\(home)/.conda/pkgs", "safe", nil),
            ("UV Cache", "bolt.horizontal.fill", "\(home)/.cache/uv", "safe", nil),
            ("Poetry Cache", "shippingbox.fill", "\(home)/Library/Caches/pypoetry", "safe", nil),
            ("pipenv Virtualenvs", "text.badge.checkmark", "\(home)/.local/share/virtualenvs", "caution", nil),
            // Java/Android
            ("Gradle Cache", "gearshape.fill", "\(home)/.gradle/caches", "safe", nil),
            ("Maven Cache", "building.columns.fill", "\(home)/.m2/repository", "safe", nil),
            ("Android Emulators", "apps.iphone", "\(home)/.android/avd", "caution", nil),
            // Containers
            ("Docker (Data)", "cube.transparent", "\(home)/Library/Containers/com.docker.docker/Data", "risky", nil),
            // Infrastructure
            ("Terraform Plugins", "server.rack", "\(home)/.terraform.d", "caution", nil),
            // PHP
            ("Composer Cache", "music.note.list", "\(home)/.composer/cache", "safe", nil),
            // Go/Rust
            ("Go Modules", "leaf.fill", "\(home)/go/pkg/mod/cache", "safe", nil),
            ("Rust Cargo", "wrench.fill", "\(home)/.cargo/registry", "safe", nil),
            // Testing
            ("Playwright Browsers", "theatermasks.fill", "\(home)/Library/Caches/ms-playwright", "safe", nil),
            ("Puppeteer Browsers", "theatermasks", "\(home)/.cache/puppeteer", "safe", nil),
            ("Prisma Engines", "cylinder.fill", "\(home)/.cache/prisma", "safe", nil),
            // Mobile
            ("Flutter/Pub Cache", "bird.fill", "\(home)/.pub-cache", "safe", nil),
            // IDEs
            ("JetBrains Cache", "laptopcomputer", "\(home)/Library/Caches/JetBrains", "safe", nil),
            // Ruby
            ("Ruby Gems", "diamond.fill", "\(home)/.gem", "safe", "Ruby"),
            ("rbenv Versions", "diamond.fill", "\(home)/.rbenv/versions", "caution", "Ruby"),
            ("mise Rubies", "diamond.fill", "\(home)/.local/share/mise/installs/ruby", "caution", "Ruby"),
            ("RVM", "diamond.fill", "\(home)/.rvm", "caution", "Ruby"),
            ("Bundler Cache", "shippingbox.fill", "\(home)/.bundle/cache", "safe", "Ruby"),
            // VS Code
            ("VS Code Cache", "laptopcomputer", "\(home)/Library/Caches/com.microsoft.VSCode", "safe", "VS Code"),
            ("VS Code Data", "laptopcomputer", "\(home)/Library/Application Support/Code/CachedData", "safe", "VS Code"),
            ("VS Code Extensions Cache", "laptopcomputer", "\(home)/Library/Application Support/Code/CachedExtensionVSIXs", "safe", "VS Code"),
            ("VS Code Chromium Cache", "laptopcomputer", "\(home)/Library/Application Support/Code/Cache", "safe", "VS Code"),
            ("VS Code Logs", "laptopcomputer", "\(home)/Library/Application Support/Code/logs", "safe", "VS Code"),
            // AI Tools
            ("Claude Desktop", "bubble.left.fill", "\(home)/Library/Application Support/Claude", "caution", "AI Tools"),
            ("Claude Code", "terminal.fill", "\(home)/.claude", "caution", "AI Tools"),
            ("HuggingFace Cache", "brain.head.profile", "\(home)/.cache/huggingface", "caution", "AI Tools"),
            ("Ollama Models", "brain", "\(home)/.ollama/models", "risky", "AI Tools"),
            ("ChatGPT Desktop", "bubble.right.fill", "\(home)/Library/Group Containers/group.com.openai.chat", "caution", "AI Tools"),
            ("Cursor Cache", "cursorarrow.rays", "\(home)/Library/Application Support/Cursor", "caution", "AI Tools"),
            ("Windsurf Cache", "wind", "\(home)/Library/Application Support/Windsurf", "caution", "AI Tools"),
            // Game Engines
            ("Unity Asset Store", "gamecontroller.fill", "\(home)/Library/Unity/Asset Store-5.x", "caution", "Game Engines"),
            ("UnityHub Templates", "square.and.arrow.down.fill", "\(home)/Library/Application Support/UnityHub/Templates", "caution", "Game Engines"),
            ("Unity Build Cache", "internaldrive.fill", "\(home)/Library/Caches/Unity", "safe", "Game Engines"),
            ("Unity Logs", "doc.text.fill", "\(home)/Library/Logs/Unity", "safe", "Game Engines"),
            ("UnityHub Cache", "gamecontroller", "\(home)/Library/Application Support/UnityHub/Cache", "safe", "Game Engines"),
            ("Godot Export Templates", "wand.and.stars", "\(home)/Library/Application Support/Godot/export_templates", "caution", "Game Engines"),
            ("Godot Cache", "wand.and.stars.fill", "\(home)/Library/Caches/Godot", "safe", "Game Engines"),
            // Version Managers (removing = losing that language version)
            ("nvm Node Versions", "number.circle.fill", "\(home)/.nvm/versions", "caution", "Version Managers"),
            ("pyenv Versions", "number.square.fill", "\(home)/.pyenv/versions", "caution", "Version Managers"),
            ("mise Installs", "square.stack.3d.up.fill", "\(home)/.local/share/mise/installs", "caution", "Version Managers"),
            // Extra JVM / Build
            ("SBT/Ivy Cache", "s.circle.fill", "\(home)/.ivy2/cache", "safe", nil),
            ("Gradle Wrapper", "gearshape.2.fill", "\(home)/.gradle/wrapper/dists", "safe", nil),
            ("Bazel Cache", "building.columns.fill", "\(home)/.cache/bazel", "safe", nil),
            // Cloud CLIs
            ("AWS CLI Cache", "cloud.fill", "\(home)/.aws/sso/cache", "safe", nil),
        ]
    }

    /// Returns list of (name, path) tuples for all known dev cache paths
    func devCachePaths() -> [(String, String)] {
        return allCachePaths().map { ($0.name, $0.path) }
    }
    
    private func scanDevCaches() {
        let devPaths = allCachePaths()
        
        var caches: [DevCache] = []
        for entry in devPaths {
            let size = directorySize(path: entry.path)
            if size > 1_048_576 { // Only show if > 1MB
                let lastAccessed = lastModifiedDate(path: entry.path)
                let daysSinceAccess = daysSince(lastAccessed)
                let suggestion = generateSuggestion(name: entry.name, size: size, daysSinceAccess: daysSinceAccess)
                let desc = DiskMonitor.cacheDescriptions[entry.name] ?? ""
                
                // Resolve DerivedData subfolders to project names
                var detail: String? = nil
                if entry.name == "Xcode DerivedData" {
                    detail = derivedDataProjectSummary()
                }
                
                caches.append(DevCache(
                    name: entry.name,
                    icon: entry.icon,
                    path: entry.path,
                    size: size,
                    lastAccessed: lastAccessed,
                    daysSinceAccess: daysSinceAccess,
                    suggestion: suggestion,
                    riskLevel: entry.riskLevel,
                    cacheDescription: desc,
                    group: entry.group,
                    detail: detail
                ))
            }
        }
        
        caches.sort { $0.size > $1.size }
        
        DispatchQueue.main.async { [weak self] in
            self?.devCaches = caches
        }
    }
    
    private func lastModifiedDate(path: String) -> Date? {
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
            "\(home)/Music",
            "\(home)/Pictures",
        ]
        
        for dir in scanDirs {
            let folderName = (dir as NSString).lastPathComponent
            findLargeFiles(in: dir, folder: folderName, threshold: threshold, results: &files, maxDepth: 3, currentDepth: 0)
        }
        
        files.sort { $0.size > $1.size }
        
        DispatchQueue.main.async { [weak self] in
            self?.largeFiles = Array(files.prefix(60))
        }
    }
    
    /// Packages that look like folders but are really one app-managed library. Trashing a single
    /// file inside one corrupts the whole library, so the scanner must never look inside them.
    private static let mediaLibraryExtensions: Set<String> = [
        "photoslibrary", "aplibrary", "migratedaplibrary",
        "fcpbundle", "imovielibrary", "theater", "tvlibrary", "logicx", "band",
    ]

    private func findLargeFiles(in path: String, folder: String, threshold: Int64, results: inout [LargeFile], maxDepth: Int, currentDepth: Int) {
        guard currentDepth < maxDepth else { return }
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }

        for item in contents {
            if item.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(item)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let ext = (item as NSString).pathExtension.lowercased()
                if DiskMonitor.mediaLibraryExtensions.contains(ext) { continue }
                findLargeFiles(in: fullPath, folder: folder, threshold: threshold, results: &results, maxDepth: maxDepth, currentDepth: currentDepth + 1)
            } else {
                // Use allocatedSize for accurate reporting (consistent with directorySize)
                if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                   let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize,
                   Int64(size) >= threshold {
                    results.append(LargeFile(
                        name: item,
                        path: fullPath,
                        size: Int64(size),
                        folder: folder
                    ))
                }
            }
        }
    }
    
    // MARK: - Cleanup Actions
    
    func deleteLargeFile(_ file: LargeFile) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let failure = self.moveToTrash(path: file.path)
            DispatchQueue.main.async {
                self.finishClean(title: file.name, freed: failure == nil ? file.size : 0, failure: failure)
            }
        }
    }

    /// Records the outcome of a clean. Credits ONLY the bytes that actually reached the Trash and
    /// surfaces the first failure, so a refused delete can never show up as "Recovered X!".
    /// Always re-scans: on failure the item is still on disk and must reappear in the list.
    private func finishClean(title: String, freed: Int64, failure: String?) {
        if freed > 0 { addToSavings(freed) }
        if let failure {
            cleanFailure = CleanFailure(title: title, reason: failure, isPermission: Self.isPermissionError(failure))
        }
        scan()
    }

    private static func isPermissionError(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("permission") || r.contains("not permitted") || r.contains("privileges")
    }

    /// Move items to Trash instead of permanent delete — user can recover for 30 days.
    /// NEVER falls back to permanent delete. If trash fails, it fails safely.
    /// Returns `nil` on success, or a human-readable reason on failure.
    private func moveToTrash(path: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            return (error as NSError).localizedDescription
        }
        // trashItem can return without throwing yet leave the item in place (TCC / volume edge
        // cases). Trust the filesystem, not the return value — otherwise we report phantom savings.
        if fm.fileExists(atPath: path) {
            return "\((path as NSString).lastPathComponent) is still on disk after the move to Trash."
        }
        return nil
    }
    
    /// Trashes every entry inside `path` (the directory itself is kept — it's a live cache dir).
    /// Returns the bytes that actually left, measured from disk rather than assumed: partial
    /// failures are normal (a file held open by Xcode or Docker) and must not be counted as freed.
    private func emptyDirectoryToTrash(path: String, sizeBefore: Int64) -> (freed: Int64, failure: String?) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
            return (0, "\((path as NSString).lastPathComponent) could not be opened.")
        }
        var failure: String?
        for item in contents {
            let fullPath = (path as NSString).appendingPathComponent(item)
            if let reason = moveToTrash(path: fullPath), failure == nil { failure = reason }
        }
        let remaining = directorySize(path: path)
        return (max(0, sizeBefore - remaining), failure)
    }

    func cleanDevCache(_ cache: DevCache) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.emptyDirectoryToTrash(path: cache.path, sizeBefore: cache.size)
            DispatchQueue.main.async {
                self.finishClean(title: cache.name, freed: result.freed, failure: result.failure)
            }
        }
    }

    /// Clean only safe caches (excludes risky caches like Docker)
    func cleanSafeCaches() {
        cleanCaches(devCaches.filter { $0.riskLevel != "risky" }, title: "Safe caches")
    }

    /// Clean ALL caches including risky ones (requires explicit user confirmation)
    func cleanAllDevCaches() {
        cleanCaches(devCaches, title: "All developer caches")
    }

    /// `caches` is snapshotted by the caller on the main thread — never read the @Published
    /// `devCaches` from the background queue.
    private func cleanCaches(_ caches: [DevCache], title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var freed: Int64 = 0
            var failure: String?
            for cache in caches {
                let result = self.emptyDirectoryToTrash(path: cache.path, sizeBefore: cache.size)
                freed += result.freed
                if failure == nil { failure = result.failure }
            }
            DispatchQueue.main.async {
                self.finishClean(title: title, freed: freed, failure: failure)
            }
        }
    }
    
    func emptyTrash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let sizeBefore = self.directorySize(path: trashPath)
            if let contents = try? fm.contentsOfDirectory(atPath: trashPath) {
                for item in contents {
                    let fullPath = (trashPath as NSString).appendingPathComponent(item)
                    try? fm.removeItem(atPath: fullPath) // Trash empty = permanent delete (intended)
                }
            }
            let remaining = self.directorySize(path: trashPath)
            DispatchQueue.main.async {
                self.finishClean(
                    title: "Trash",
                    freed: max(0, sizeBefore - remaining),
                    failure: remaining > 0 ? "Some items in the Trash could not be removed." : nil
                )
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

    /// Opens System Settings on the pane where the user can let ClearDisk move files to the Trash.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Project Artifact Scanner (inspired by kondo/npkill)
    
    /// Known project types: (marker file, artifact directory name, project type label)
    struct ProjectType {
        let markers: [String]   // ANY one present = project of this type. Supports glob like "*.csproj".
        let artifacts: [String] // EACH existing one becomes a row. Supports glob like "*.egg-info".
        let label: String
    }

    static let projectTypes: [ProjectType] = [
        // JavaScript / TypeScript ecosystem — many possible per-project caches
        ProjectType(
            markers: ["package.json", "pnpm-workspace.yaml", "bun.lockb", "yarn.lock", "deno.json"],
            artifacts: ["node_modules", ".next", ".nuxt", ".svelte-kit", ".angular", ".turbo", ".vite", ".parcel-cache", ".yarn/cache", ".cache", ".expo", "dist", "build", "out", "coverage", "storybook-static"],
            label: "Node.js / JS"
        ),
        // Python — none of this was covered per-project before. NOTE: .env intentionally NOT listed (it is user config / secrets, not a cache).
        ProjectType(
            markers: ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile", "poetry.lock", "uv.lock"],
            artifacts: [".venv", "venv", "env", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", "dist", "build", "*.egg-info", ".eggs", "htmlcov", "coverage"],
            label: "Python"
        ),
        ProjectType(markers: ["Cargo.toml"], artifacts: ["target"], label: "Rust"),
        ProjectType(markers: ["Package.swift"], artifacts: [".build", ".swiftpm"], label: "Swift PM"),
        // CocoaPods / Carthage — per-project, often hundreds of MB
        ProjectType(markers: ["Podfile"], artifacts: ["Pods"], label: "CocoaPods"),
        ProjectType(markers: ["Cartfile", "Cartfile.private"], artifacts: ["Carthage/Build", "Carthage/Checkouts"], label: "Carthage"),
        // Xcode project (in-project build/DerivedData; global DerivedData already covered in Caches tab)
        ProjectType(markers: ["*.xcodeproj", "*.xcworkspace"], artifacts: ["build", "DerivedData"], label: "Xcode"),
        ProjectType(markers: ["go.mod"], artifacts: ["vendor"], label: "Go"),
        ProjectType(markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], artifacts: ["build", ".gradle", "app/build", "out"], label: "Gradle"),
        ProjectType(markers: ["pom.xml"], artifacts: ["target"], label: "Maven"),
        ProjectType(markers: ["composer.json"], artifacts: ["vendor"], label: "PHP/Composer"),
        ProjectType(markers: ["Gemfile"], artifacts: ["vendor/bundle", ".bundle", "tmp/cache"], label: "Ruby"),
        ProjectType(markers: ["pubspec.yaml"], artifacts: [".dart_tool", "build"], label: "Flutter/Dart"),
        ProjectType(markers: ["CMakeLists.txt"], artifacts: ["build", "cmake-build-debug", "cmake-build-release"], label: "CMake"),
        ProjectType(markers: ["main.tf"], artifacts: [".terraform"], label: "Terraform"),
        // Game engines — sen Godot kullan\u0131yorsun, Unity/Unreal de buraya
        ProjectType(markers: ["project.godot"], artifacts: [".godot", ".import"], label: "Godot"),
        // Unity — NOTE: "Build"/"Builds" intentionally NOT listed; those hold EXPORTED player builds the
        // user ships/keeps (and that take a long time to re-export), not regenerable caches.
        ProjectType(markers: ["ProjectSettings/ProjectVersion.txt", "Assembly-CSharp.csproj"], artifacts: ["Library", "Temp", "Logs", "obj"], label: "Unity"),
        // Unreal — NOTE: "Saved/" and "Build/" intentionally NOT listed; Saved holds editor prefs, autosaves
        // and crash logs, and Build/ holds packaged/exported builds — both are user output, not caches.
        ProjectType(markers: ["*.uproject"], artifacts: ["Binaries", "Intermediate", "DerivedDataCache"], label: "Unreal"),
        // .NET / C# — MUST stay below the game engines: a Unity project ships an Assembly-CSharp.csproj,
        // so it matches these markers too, and the first type to claim a directory is the one that names it.
        ProjectType(markers: ["*.sln", "*.csproj", "*.fsproj", "*.vbproj"], artifacts: ["bin", "obj", "packages"], label: ".NET"),
        // Niche but big when used
        ProjectType(markers: ["stack.yaml", "*.cabal"], artifacts: [".stack-work", "dist-newstyle", "dist"], label: "Haskell"),
        ProjectType(markers: ["mix.exs"], artifacts: ["_build", "deps", ".elixir_ls"], label: "Elixir"),
        ProjectType(markers: ["build.zig"], artifacts: ["zig-out", "zig-cache", ".zig-cache"], label: "Zig"),
        // Crystal — deps live in lib/, source in src/ (Crystal convention). lib/ is only cleaned when a
        // shard.lock proves `shards install` ran (see hasCacheProof), so a hand-written lib/ is never touched.
        ProjectType(markers: ["shard.yml"], artifacts: ["lib", ".crystal"], label: "Crystal"),
    ]

    /// Artifact directory names that collide with common user/source folder names. These are only ever
    /// surfaced as deletable caches when `hasCacheProof` finds definitive evidence of what they really are.
    static let ambiguousArtifactNames: Set<String> = ["env", "venv", ".venv", "lib"]

    /// Definitive proof that an ambiguously-named directory is a regenerable cache and not user data/source.
    /// Returns `true` for any non-ambiguous name (no extra proof required).
    static func hasCacheProof(artifactPath: String, projectPath: String, name: String) -> Bool {
        let fm = FileManager.default
        switch name {
        case "env", "venv", ".venv":
            // A real Python virtualenv always contains pyvenv.cfg (python -m venv / virtualenv 20+) or a
            // bin/activate script. A bare env/ or venv/ without either is user data — leave it alone.
            return fm.fileExists(atPath: (artifactPath as NSString).appendingPathComponent("pyvenv.cfg"))
                || fm.fileExists(atPath: (artifactPath as NSString).appendingPathComponent("bin/activate"))
        case "lib":
            // Crystal deps only: require a shard.lock in the project root (proof `shards install` ran).
            return fm.fileExists(atPath: (projectPath as NSString).appendingPathComponent("shard.lock"))
        default:
            return true
        }
    }
    
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
            self?.projectArtifacts = Array(artifacts.prefix(100)) // top 100 biggest (raised from 50 with more project types)
        }
    }
    
    private func findProjectArtifacts(in path: String, results: inout [ProjectArtifact], maxDepth: Int, currentDepth: Int) {
        guard currentDepth < maxDepth else { return }
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        let contentsSet = Set(contents)
        
        // Try every project type. A type matches if any marker exists. Each matching artifact yields its own row.
        var anyArtifactFound = false
        // One directory legitimately matches several project types: a Unity project also carries a
        // *.csproj (so it is a .NET project too), and a JS+Python monorepo root shares dist/, build/
        // and coverage/. Without this, the same directory is listed once per matching type — the size
        // is counted twice in the totals, and cleaning the second row fails on an already-trashed path.
        var seenArtifactPaths = Set<String>()
        for pt in DiskMonitor.projectTypes {
            let hasMarker = pt.markers.contains { DiskMonitor.entryExists(in: path, contents: contentsSet, name: $0) }
            guard hasMarker else { continue }

            for art in pt.artifacts {
                let artifactPaths = DiskMonitor.resolveEntries(in: path, contents: contentsSet, name: art)
                for artifactPath in artifactPaths {
                    // First project type to claim a directory wins its label.
                    guard seenArtifactPaths.insert(artifactPath).inserted else { continue }

                    // Safety guard: only ever treat directories as cache artifacts. A literal-named entry that
                    // happens to be a regular file (e.g. an .env file or a stray same-named text file) must not be
                    // surfaced or moved to Trash from this scanner.
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: artifactPath, isDirectory: &isDir), isDir.boolValue else { continue }

                    // Ambiguous names (env/venv/.venv/lib) collide with real user/source folders. Only surface
                    // them when there is definitive proof they are a regenerable cache (see hasCacheProof).
                    let artifactLeaf = (artifactPath as NSString).lastPathComponent
                    if DiskMonitor.ambiguousArtifactNames.contains(artifactLeaf),
                       !DiskMonitor.hasCacheProof(artifactPath: artifactPath, projectPath: path, name: artifactLeaf) {
                        continue
                    }

                    let size = directorySize(path: artifactPath)
                    guard size > 10_485_760 else { continue } // > 10 MB
                    let projectName = (path as NSString).lastPathComponent
                    let lastModified = lastModifiedDate(path: artifactPath)
                    let days = daysSince(lastModified)
                    let displayArtifactName = artifactLeaf

                    results.append(ProjectArtifact(
                        projectName: projectName,
                        projectPath: path,
                        artifactPath: artifactPath,
                        artifactName: displayArtifactName,
                        projectType: pt.label,
                        size: size,
                        lastModified: lastModified,
                        daysSinceModified: days
                    ))
                    anyArtifactFound = true
                }
            }
        }
        // If we identified at least one project artifact at this level, treat this dir as a project root
        // and don't recurse into its subdirectories (keeps scans fast and avoids nested duplicate hits).
        if anyArtifactFound { return }
        
        // Skip known artifact / VCS dirs when recursing
        let skipDirs: Set<String> = [
            "node_modules", ".git", "target", ".build", "build", "vendor", ".dart_tool", "Pods", "__pycache__",
            ".venv", "venv", "env", "lib", ".terraform", ".next", ".nuxt", ".svelte-kit", ".angular", ".turbo", ".vite",
            ".parcel-cache", ".yarn", ".gradle", "Carthage", "DerivedData", "bin", "obj", ".godot", ".import",
            "Library", "Temp", "Logs", "Binaries", "Intermediate", "Saved", "DerivedDataCache",
            ".stack-work", "dist-newstyle", "_build", "deps", "zig-out", "zig-cache", ".zig-cache",
            ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", ".eggs"
        ]
        
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
    
    // MARK: - Marker / artifact lookup helpers (support simple glob like "*.csproj")
    
    /// Checks whether a file/dir matching `name` (literal or simple glob with one `*`) exists directly inside `parent`.
    /// Handles relative paths with `/` by traversing component-by-component.
    private static func entryExists(in parent: String, contents: Set<String>, name: String) -> Bool {
        if name.contains("/") {
            // e.g. "ProjectSettings/ProjectVersion.txt" — fall back to literal lookup
            return FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent(name))
        }
        if name.contains("*") {
            return contents.contains { globMatch($0, pattern: name) }
        }
        return contents.contains(name)
    }
    
    /// Returns the full paths of all entries inside `parent` that match `name` (literal or simple glob).
    private static func resolveEntries(in parent: String, contents: Set<String>, name: String) -> [String] {
        if name.contains("/") {
            let full = (parent as NSString).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: full) ? [full] : []
        }
        if name.contains("*") {
            return contents.filter { globMatch($0, pattern: name) }
                           .map { (parent as NSString).appendingPathComponent($0) }
        }
        return contents.contains(name) ? [(parent as NSString).appendingPathComponent(name)] : []
    }
    
    /// Minimal glob: supports a single `*` either as prefix (`*.ext`) or suffix (`prefix*`).
    /// Falls back to NSPredicate LIKE for any other patterns.
    private static func globMatch(_ name: String, pattern: String) -> Bool {
        if !pattern.contains("*") { return name == pattern }
        let starCount = pattern.filter { $0 == "*" }.count
        if starCount == 1 {
            if pattern.hasPrefix("*") {
                return name.hasSuffix(String(pattern.dropFirst()))
            }
            if pattern.hasSuffix("*") {
                return name.hasPrefix(String(pattern.dropLast()))
            }
        }
        return NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: name)
    }
    
    /// Clean a single project artifact (move to trash)
    func cleanProjectArtifact(_ artifact: ProjectArtifact) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let failure = self.moveToTrash(path: artifact.artifactPath)
            DispatchQueue.main.async {
                // Only log history for a cache that actually reached the Trash — otherwise the
                // history claims a cleanup that never happened.
                if failure == nil {
                    self.appendProjectCleanHistory(ProjectCleanHistoryEntry(
                        projectName: artifact.projectName,
                        projectPath: artifact.projectPath,
                        artifactName: artifact.artifactName,
                        artifactPath: artifact.artifactPath,
                        projectType: artifact.projectType,
                        size: artifact.size,
                        cleanedAt: Date()
                    ))
                }
                self.finishClean(
                    title: "\(artifact.projectName) › \(artifact.artifactName)",
                    freed: failure == nil ? artifact.size : 0,
                    failure: failure
                )
            }
        }
    }
    
    // MARK: - Helpers
    func directorySize(path: String) -> Int64 {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey],
            options: [],  // Don't skip hidden files — caches often contain them
            errorHandler: nil
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey]),
                  values.isRegularFile == true else { continue }
            // Use totalFileAllocatedSize (accounts for sparse files like Docker.raw)
            // Falls back to fileAllocatedSize if total isn't available
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            // Hardlink-aware: a file with N hard links only frees `size / N` bytes when one link is removed.
            // This is critical for pnpm / Bun / Yarn Berry / Cargo registry stores that hardlink into project caches —
            // otherwise we wildly overestimate how much disk space cleaning would actually free.
            let links = max(values.linkCount ?? 1, 1)
            totalSize += Int64(size / links)
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
    let group: String? // grouping key: "Xcode", "VS Code", "AI Tools", "Ruby", or nil
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
    let folder: String // e.g. "Downloads", "Music"
}

/// A clean that did not free what it promised — the item is still on disk.
/// Surfaced to the user instead of being swallowed, so "Recovered X!" always means it really went.
struct CleanFailure: Identifiable {
    let id = UUID()
    let title: String      // what we tried to clean
    let reason: String     // the system's own explanation
    let isPermission: Bool // true → the fix is granting Full Disk Access
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
        case "Node.js / JS": return "cube.box.fill"
        case "Python": return "ladybug.fill"
        case "Rust": return "wrench.fill"
        case "Swift PM": return "swift"
        case "CocoaPods": return "shippingbox.fill"
        case "Carthage": return "tram.fill"
        case "Xcode": return "hammer.fill"
        case "Go": return "leaf.fill"
        case "Gradle": return "gearshape.fill"
        case "Maven": return "building.columns.fill"
        case "PHP/Composer": return "music.note.list"
        case "Ruby": return "diamond.fill"
        case "Flutter/Dart": return "bird.fill"
        case "CMake": return "hammer.fill"
        case "Terraform": return "cloud.fill"
        case ".NET": return "square.grid.2x2.fill"
        case "Godot": return "gamecontroller.fill"
        case "Unity": return "cube.transparent"
        case "Unreal": return "cube.transparent.fill"
        case "Haskell": return "lambda"
        case "Elixir": return "drop.fill"
        case "Zig": return "bolt.fill"
        case "Crystal": return "sparkles"
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

// History entry for a cleaned per-project cache artifact
struct ProjectCleanHistoryEntry: Codable, Identifiable {
    var id = UUID()
    let projectName: String
    let projectPath: String
    let artifactName: String
    let artifactPath: String
    let projectType: String
    let size: Int64
    let cleanedAt: Date
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
