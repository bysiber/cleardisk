import Darwin
import Foundation

struct DirectoryMeasurement: Sendable {
    var bytes: Int64 = 0
    var files: Int = 0
    var errorCount: Int = 0
    var firstError: String?
    var isComplete: Bool { errorCount == 0 }

    mutating func recordError(path: String, code: Int32) {
        errorCount += 1
        if firstError == nil {
            firstError = "\(path): \(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)"
        }
    }

    /// Allocated bytes attributed to directory entries, not a promise of space reclaimed.
    /// Hard links share an allocation; deleting one of several links need not free any blocks.
    static func measure(path: String, isCancelled: () -> Bool = { false }) -> Self {
        var result = Self()
        guard !isCancelled() else {
            result.recordError(path: path, code: ECANCELED)
            return result
        }
        guard let cPath = strdup(path) else {
            result.recordError(path: path, code: ENOMEM)
            return result
        }
        defer { free(cPath) }

        // Missing optional cache roots are empty. Other errors must remain visible.
        var rootStat = stat()
        if lstat(cPath, &rootStat) != 0 {
            let code = errno
            if code != ENOENT { result.recordError(path: path, code: code) }
            return result
        }

        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // Keep argv storage alive for the entire traversal; each call owns its FTS handle.
        paths.withUnsafeMutableBufferPointer { buffer in
            guard let tree = fts_open(buffer.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                result.recordError(path: path, code: errno)
                return
            }
            defer {
                if fts_close(tree) != 0 { result.recordError(path: path, code: errno) }
            }
            while true {
                if isCancelled() {
                    result.recordError(path: path, code: ECANCELED)
                    break
                }
                errno = 0
                guard let node = fts_read(tree) else {
                    let code = errno
                    if code != 0 { result.recordError(path: path, code: code) }
                    break
                }
                switch Int32(node.pointee.fts_info) {
                case FTS_F:
                    let metadata = node.pointee.fts_statp.pointee
                    let (allocated, overflow) = max(0, Int64(metadata.st_blocks)).multipliedReportingOverflow(by: 512)
                    let (total, sumOverflow) = result.bytes.addingReportingOverflow(
                        allocated / max(1, Int64(metadata.st_nlink))
                    )
                    if overflow || sumOverflow {
                        result.recordError(path: path, code: EOVERFLOW)
                        return
                    }
                    result.bytes = total
                    result.files += 1
                case FTS_DC:
                    result.recordError(path: String(cString: node.pointee.fts_path), code: ELOOP)
                case FTS_DNR, FTS_ERR, FTS_NS:
                    let code = node.pointee.fts_errno
                    result.recordError(path: String(cString: node.pointee.fts_path), code: code == 0 ? EIO : code)
                default:
                    break
                }
            }
        }
        return result
    }
}
