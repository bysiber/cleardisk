import XCTest
@testable import ClearDisk

final class FullDiskAccessProbeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearDiskFDA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testMissingCandidatesAreDenied() {
        let missing = scratch.appendingPathComponent("does-not-exist")
        XCTAssertEqual(FullDiskAccessProbe.evaluate(missing), .missing)
        XCTAssertFalse(FullDiskAccessProbe.isGranted(candidates: [missing]))
    }

    func testReadableDirectoryCountsAsGranted() throws {
        let dir = scratch.appendingPathComponent("Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: dir.appendingPathComponent("Bookmarks.plist"))
        XCTAssertEqual(FullDiskAccessProbe.evaluate(dir), .granted)
        XCTAssertTrue(FullDiskAccessProbe.isGranted(candidates: [
            scratch.appendingPathComponent("missing-tcc.db"),
            dir,
        ]))
    }

    func testSQLiteHeaderOnTCCDatabaseCountsAsGranted() throws {
        let db = scratch.appendingPathComponent("TCC.db")
        try Data("SQLite format 3\0more".utf8).write(to: db)
        XCTAssertEqual(FullDiskAccessProbe.evaluate(db), .granted)
        XCTAssertTrue(FullDiskAccessProbe.isGranted(candidates: [db]))
    }

    func testEmptyProtectedFileCountsAsDenied() throws {
        let db = scratch.appendingPathComponent("TCC.db")
        try Data().write(to: db)
        XCTAssertEqual(FullDiskAccessProbe.evaluate(db), .denied)
        XCTAssertFalse(FullDiskAccessProbe.isGranted(candidates: [db]))
    }

    func testMissingPathDoesNotMaskALaterReadableProbe() throws {
        let dir = scratch.appendingPathComponent("Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(FullDiskAccessProbe.isGranted(candidates: [
            scratch.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            dir,
        ]))
    }

    func testUnreadableDirectoryCountsAsDenied() throws {
        let dir = scratch.appendingPathComponent("stocks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        XCTAssertEqual(FullDiskAccessProbe.evaluate(dir), .denied)
        XCTAssertFalse(FullDiskAccessProbe.isGranted(candidates: [dir]))
    }
}
