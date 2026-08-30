import XCTest
@testable import ClearDisk

final class CleanupSafetyTests: XCTestCase {
    private func cache(name: String, risk: String) -> DevCache {
        DevCache(
            name: name,
            icon: "externaldrive",
            path: "/tmp/\(name)",
            size: 1,
            lastAccessed: nil,
            daysSinceAccess: nil,
            suggestion: nil,
            riskLevel: risk,
            cacheDescription: "",
            group: nil
        )
    }

    func testSafeBulkCleanOnlyAcceptsExplicitlySafeItems() {
        XCTAssertTrue(DiskMonitor.isEligibleForSafeBulkClean(cache(name: "Safe", risk: "safe")))
        XCTAssertFalse(DiskMonitor.isEligibleForSafeBulkClean(cache(name: "Caution", risk: "caution")))
        XCTAssertFalse(DiskMonitor.isEligibleForSafeBulkClean(cache(name: "Risky", risk: "risky")))
    }

    func testRiskySelectionRequiresAcknowledgement() {
        XCTAssertFalse(DiskMonitor.requiresDataLossAcknowledgement(for: [cache(name: "Safe", risk: "safe")]))
        XCTAssertTrue(DiskMonitor.requiresDataLossAcknowledgement(for: [
            cache(name: "Safe", risk: "safe"),
            cache(name: "Docker", risk: "risky")
        ]))
    }

    func testKnownUserDataStoresStayRisky() {
        let definitions = Dictionary(
            uniqueKeysWithValues: DiskMonitor().allCachePaths().map { ($0.name, $0.riskLevel) }
        )
        for name in ["Docker (Data)", "Claude Desktop", "Claude Code", "Cursor", "Windsurf"] {
            XCTAssertEqual(definitions[name], "risky", "\(name) must never enter a one-click safe cleanup")
        }
    }

    func testEveryCacheDefinitionHasADescription() {
        // MainView renders `DiskMonitor.cacheDescriptions[entry.name] ?? ""` — a name added to
        // allCachePaths() without a matching key here silently shows a blank description instead
        // of failing to build.
        let names = DiskMonitor().allCachePaths().map(\.name)
        for name in names {
            XCTAssertNotNil(
                DiskMonitor.cacheDescriptions[name],
                "\(name) is missing an entry in cacheDescriptions"
            )
        }
    }

    func testCacheDefinitionsNeverTargetBroadUserDirectories() {
        let paths = DiskMonitor().allKnownCacheDefinitions().map(\.path)
        let forbiddenSuffixes = ["/Library", "/Library/Application Support", "/Documents", "/Desktop", "/Downloads"]
        XCTAssertEqual(paths.count, Set(paths).count, "Cleanup paths must be unique")
        XCTAssertFalse(paths.contains("/"), "A cleanup definition targets the filesystem root")
        for path in paths {
            XCTAssertFalse(
                forbiddenSuffixes.contains { path.hasSuffix($0) },
                "A cleanup definition targets a dangerously broad directory"
            )
        }
    }

    func testAppCachesAreIsolatedFromDeveloperDefinitions() {
        let monitor = DiskMonitor()
        let appDefinitions = monitor.appCacheDefinitions()
        let developerPaths = Set(monitor.allCachePaths().map(\.path))
        let appPaths = Set(appDefinitions.map(\.path))

        XCTAssertFalse(appDefinitions.isEmpty)
        XCTAssertTrue(appDefinitions.allSatisfy { $0.section == .app })
        XCTAssertTrue(appDefinitions.allSatisfy { ["safe", "caution"].contains($0.riskLevel) })
        XCTAssertTrue(developerPaths.isDisjoint(with: appPaths))
    }

    func testAppCacheRegistryIncludesMajorBrowsers() {
        let definitions = DiskMonitor().appCacheDefinitions()
        let names = Set(definitions.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Google Chrome", "Firefox", "Safari"]))

        for browser in definitions.filter({ ["Google Chrome", "Firefox", "Safari"].contains($0.name) }) {
            XCTAssertEqual(browser.riskLevel, "safe")
            XCTAssertTrue(browser.safetyDetails?.keeps.localizedCaseInsensitiveContains("cookies") == true)
            XCTAssertTrue(browser.safetyDetails?.keeps.localizedCaseInsensitiveContains("extensions") == true)
        }
    }

    func testApplicationSupportTargetsAreExactCacheSubdirectories() {
        let definitions = DiskMonitor().appCacheDefinitions()
        let applicationSupportPaths = definitions.map(\.path).filter { $0.contains("/Library/Application Support/") }
        let allowedLeafNames = Set(["Cache", "Code Cache", "GPUCache", "htmlcache"])

        XCTAssertFalse(applicationSupportPaths.isEmpty)
        for path in applicationSupportPaths {
            XCTAssertTrue(
                allowedLeafNames.contains((path as NSString).lastPathComponent),
                "Application Support targets must be exact cache subdirectories: \(path)"
            )
        }
    }

    func testAppCacheTargetsNeverOverlap() {
        let paths = DiskMonitor().appCacheDefinitions().map(\.path)
        for (index, path) in paths.enumerated() {
            for other in paths.dropFirst(index + 1) {
                XCTAssertFalse(
                    path.hasPrefix(other + "/") || other.hasPrefix(path + "/"),
                    "Overlapping targets could count or clean the same files twice: \(path), \(other)"
                )
            }
        }
    }

    func testSparkleDownloadsRequireReview() throws {
        let fm = FileManager.default
        let temporaryHome = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sparkle = temporaryHome.appendingPathComponent("Library/Caches/com.example.app/org.sparkle-project.Sparkle", isDirectory: true)
        try fm.createDirectory(at: sparkle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporaryHome) }

        let definition = AppCacheCatalog.definitions(home: temporaryHome.path)
            .first { $0.path == sparkle.path }
        XCTAssertEqual(definition?.riskLevel, "caution")
        XCTAssertTrue(definition?.safetyDetails?.note.localizedCaseInsensitiveContains("review") == true)
    }

    func testShipItDownloadsRequireReview() throws {
        let fm = FileManager.default
        let temporaryHome = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shipIt = temporaryHome.appendingPathComponent("Library/Caches/com.example.editor.ShipIt", isDirectory: true)
        try fm.createDirectory(at: shipIt, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporaryHome) }

        let definition = AppCacheCatalog.definitions(home: temporaryHome.path)
            .first { $0.path == shipIt.path }
        XCTAssertEqual(definition?.riskLevel, "caution")
        XCTAssertTrue(definition?.safetyDetails?.note.localizedCaseInsensitiveContains("quit") == true)
    }

    func testCopilotCleanupNeverTargetsSessionStorage() {
        let definitions = DiskMonitor().allCachePaths()
        let copilot = definitions.filter { $0.name.contains("Copilot") }

        XCTAssertFalse(copilot.isEmpty)
        XCTAssertTrue(copilot.allSatisfy { $0.path.contains("/Library/Caches/") })
        XCTAssertFalse(copilot.contains { $0.path.contains("/.copilot") })
        XCTAssertTrue(copilot.allSatisfy { $0.riskLevel == "caution" })
    }
}
