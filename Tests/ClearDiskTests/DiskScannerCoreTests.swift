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
}
