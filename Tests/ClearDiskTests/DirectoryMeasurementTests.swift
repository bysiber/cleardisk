import Darwin
import Foundation
import XCTest
@testable import ClearDisk

final class DirectoryMeasurementTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func foundationBytes(_ root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey]
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)))
        var total: Int64 = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                total += Int64((values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) / max(1, values.linkCount ?? 1))
            }
        }
        return total
    }

    func testHiddenFilesHardlinksSparseFilesAndSymlinkCycle() throws {
        let root = try fixture()
        let original = root.appendingPathComponent(".hidden")
        try Data(repeating: 42, count: 16384).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("hardlink"))
        let sparse = root.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        let measured = DirectoryMeasurement.measure(path: root.path)
        XCTAssertTrue(measured.isComplete, measured.firstError ?? "")
        XCTAssertEqual(measured.files, 3)
        XCTAssertEqual(measured.bytes, try foundationBytes(root))
        XCTAssertLessThan(measured.bytes, 1 << 30)
    }

    func testMissingRootIsEmptyButInvalidParentIsAnError() throws {
        let root = try fixture()
        XCTAssertTrue(DirectoryMeasurement.measure(path: root.appendingPathComponent("missing").path).isComplete)
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let result = DirectoryMeasurement.measure(path: file.appendingPathComponent("child").path)
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.firstError)
    }

    func testResourceForkMatchesFoundationAllocation() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("forked")
        try Data(repeating: 1, count: 4096).write(to: file)
        let descriptor = open(file.path + "/..namedfork/rsrc", O_WRONLY | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(repeating: 2, count: 16384))
        try handle.close()
        let result = DirectoryMeasurement.measure(path: root.path)
        XCTAssertTrue(result.isComplete, result.firstError ?? "")
        XCTAssertEqual(result.bytes, try foundationBytes(root))
    }

    func testUnreadableChildDoesNotLookComplete() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test user") }
        let root = try fixture()
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: denied.appendingPathComponent("file"))
        XCTAssertEqual(chmod(denied.path, 0), 0)
        defer { chmod(denied.path, 0o700) }
        let result = DirectoryMeasurement.measure(path: root.path)
        XCTAssertFalse(result.isComplete)
        XCTAssertGreaterThan(result.errorCount, 0)
    }

    func testCancellationDuringTraversalIsIncomplete() throws {
        let root = try fixture()
        try Data([1]).write(to: root.appendingPathComponent("file"))
        var checks = 0
        let result = DirectoryMeasurement.measure(path: root.path) {
            checks += 1
            return checks >= 3
        }
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.errorCount, 1)
    }

    func testParallelMeasurementsHaveIndependentState() throws {
        let root = try fixture()
        try Data(repeating: 7, count: 8192).write(to: root.appendingPathComponent("file"))
        let expected = DirectoryMeasurement.measure(path: root.path)
        let results = ScanResults<DirectoryMeasurement>()
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            results.append(DirectoryMeasurement.measure(path: root.path))
        }
        XCTAssertEqual(results.snapshot().count, 40)
        XCTAssertTrue(results.snapshot().allSatisfy { $0.isComplete && $0.bytes == expected.bytes && $0.files == expected.files })
    }

    func testMountedChildIsExcluded() throws {
        guard ProcessInfo.processInfo.environment["CLEARDISK_TEST_MOUNTS"] == "1" else {
            throw XCTSkip("Set CLEARDISK_TEST_MOUNTS=1 to run the disk-image integration test")
        }
        let root = try fixture()
        let image = try fixture().appendingPathComponent("fixture.dmg")
        let mount = root.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func hdiutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            if process.terminationStatus != 0 { throw NSError(domain: "hdiutil", code: Int(process.terminationStatus)) }
        }
        try hdiutil(["create", "-size", "32m", "-fs", "HFS+", "-volname", "ScanTest", image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? hdiutil(["detach", mount.path]) }
        try Data(repeating: 1, count: 1 << 20).write(to: mount.appendingPathComponent("excluded"))
        let result = DirectoryMeasurement.measure(path: root.path)
        XCTAssertTrue(result.isComplete, result.firstError ?? "")
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(result.bytes, 0)
    }

    func testPolicyThrottlesAllNonNominalStatesAndLowPower() {
        for cores in [1, 2, 4, 8, 24] {
            let lowPower = ScanResourcePolicy(cores: cores, lowPower: true, thermalState: .nominal)
            XCTAssertEqual(lowPower.workers, 1)
            XCTAssertEqual(lowPower.backendLimits.traversal, 1)
            XCTAssertEqual(lowPower.backendLimits.classification, 1)
            XCTAssertEqual(lowPower.backendLimits.atomic, 1)
            for state in [ProcessInfo.ThermalState.fair, .serious, .critical] {
                XCTAssertEqual(ScanResourcePolicy(cores: cores, lowPower: false, thermalState: state).workers, 1)
            }
        }
        XCTAssertEqual(ScanResourcePolicy(cores: 2, lowPower: false, thermalState: .nominal).workers, 1)
        XCTAssertEqual(ScanResourcePolicy(cores: 8, lowPower: false, thermalState: .nominal).workers, 2)
    }
}
