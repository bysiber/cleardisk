import Foundation
import XCTest
@testable import DiskScannerCore

final class DiskScannerCoreTests: XCTestCase {
    @MainActor
    func testFolderScanBuildsQueryableTreeAndAggregatesFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearDiskScannerTests-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 1_024).write(to: root.appendingPathComponent("first.bin"))
        try Data(repeating: 2, count: 2_048).write(to: nested.appendingPathComponent("second.bin"))

        let scanner = DiskScanner()
        var completedSnapshot: DiskScanSnapshot?
        for try await event in scanner.events(for: DiskScanRequest(rootURL: root)) {
            if case .completed(let snapshot) = event {
                completedSnapshot = snapshot
            }
        }

        let snapshot = try XCTUnwrap(completedSnapshot)
        let scannedRoot = try XCTUnwrap(snapshot.root)
        XCTAssertTrue(scannedRoot.isDirectory)
        XCTAssertGreaterThanOrEqual(snapshot.statistics.fileCount, 2)
        XCTAssertGreaterThanOrEqual(snapshot.statistics.logicalBytes, 3_072)
        XCTAssertEqual(snapshot.children(of: scannedRoot.id).count, 2)
    }

    @MainActor
    func testMaterializedDepthLimitKeepsDeepScanMemoryBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearDiskBoundedScannerTests-\(UUID().uuidString)", isDirectory: true)
        let levelOne = root.appendingPathComponent("One", isDirectory: true)
        let levelTwo = levelOne.appendingPathComponent("Two", isDirectory: true)
        let levelThree = levelTwo.appendingPathComponent("Three", isDirectory: true)
        try FileManager.default.createDirectory(at: levelThree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 7, count: 4_096)
            .write(to: levelThree.appendingPathComponent("payload.bin"))

        let scanner = DiskScanner()
        var completedSnapshot: DiskScanSnapshot?
        let request = DiskScanRequest(
            rootURL: root,
            includesHiddenItems: true,
            maximumMaterializedDepth: 2
        )
        for try await event in scanner.events(for: request) {
            if case .completed(let snapshot) = event {
                completedSnapshot = snapshot
            }
        }

        let snapshot = try XCTUnwrap(completedSnapshot)
        let rootNode = try XCTUnwrap(snapshot.root)
        let firstLevelNode = try XCTUnwrap(snapshot.children(of: rootNode.id).first)
        let summarizedNode = try XCTUnwrap(snapshot.children(of: firstLevelNode.id).first)
        XCTAssertTrue(summarizedNode.wasSummarized)
        XCTAssertTrue(summarizedNode.childIDs.isEmpty)
        XCTAssertEqual(summarizedNode.descendantFileCount, 1)
        XCTAssertEqual(summarizedNode.name, "Two")
        XCTAssertEqual(snapshot.nodeCount, 3)
        XCTAssertEqual(snapshot.statistics.fileCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.statistics.logicalBytes, 4_096)
    }
}
