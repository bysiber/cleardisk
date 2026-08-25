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
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .path + "/"

        XCTAssertFalse(appDefinitions.isEmpty)
        XCTAssertTrue(appDefinitions.allSatisfy { $0.section == .app })
        XCTAssertTrue(appDefinitions.allSatisfy { $0.riskLevel == "safe" })
        XCTAssertTrue(appDefinitions.allSatisfy { $0.path.hasPrefix(cacheRoot) })
        XCTAssertTrue(developerPaths.isDisjoint(with: appPaths))
    }

    func testAppCacheRegistryIncludesMajorBrowsers() {
        let names = Set(DiskMonitor().appCacheDefinitions().map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Google Chrome", "Firefox", "Safari"]))
    }
}
