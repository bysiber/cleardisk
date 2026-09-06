import Foundation

/// macOS has no public API that reports Full Disk Access. ClearDisk used to treat a
/// successful open of `~/Library/Application Support/com.apple.TCC/TCC.db` as proof.
/// That user database is gone on macOS 27 (it moved into a ProtectedSystem container),
/// so `fileExists` always failed and onboarding stayed on "Not enabled yet".
///
/// Probe real reads instead. Missing paths are skipped. The first existing candidate
/// decides: a successful read means granted, `Operation not permitted` means denied.
enum FullDiskAccessProbe {
    enum Outcome {
        case granted
        case denied
        case missing
    }

    static var defaultCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Safari"),
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Containers/com.apple.stocks"),
        ]
    }

    static func isGranted(candidates: [URL] = defaultCandidates) -> Bool {
        for url in candidates {
            switch evaluate(url) {
            case .granted:
                return true
            case .denied:
                return false
            case .missing:
                continue
            }
        }
        return false
    }

    static func evaluate(_ url: URL, fileManager: FileManager = .default) -> Outcome {
        do {
            _ = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            return .granted
        } catch {
            if isMissing(error) {
                return readFileProbe(url)
            }
            if isNotADirectory(error) {
                return readFileProbe(url)
            }
            if isPermissionDenied(error) {
                return .denied
            }
            return readFileProbe(url)
        }
    }

    private static let sqliteHeader = Data("SQLite format 3\0".utf8)

    private static func readFileProbe(_ url: URL) -> Outcome {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: sqliteHeader.count) ?? Data()
            if header.isEmpty {
                return .denied
            }
            if url.pathExtension == "db" {
                return header == sqliteHeader ? .granted : .denied
            }
            return .granted
        } catch {
            if isMissing(error) {
                return .missing
            }
            return .denied
        }
    }

    private static func posixCode(_ error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let posix = error as? POSIXError {
            return posix.code.rawValue
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                return true
            }
        }
        return posixCode(error) == ENOENT
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if let code = posixCode(error), code == EPERM || code == EACCES {
            return true
        }
        let text = nsError.localizedDescription.lowercased()
        return text.contains("not permitted") || text.contains("permission denied")
    }

    private static func isNotADirectory(_ error: Error) -> Bool {
        if posixCode(error) == ENOTDIR {
            return true
        }
        let text = (error as NSError).localizedDescription.lowercased()
        return text.contains("not a directory") || text.contains("isn’t a directory")
    }
}
