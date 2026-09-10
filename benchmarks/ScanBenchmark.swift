import Foundation

@main
enum ScanBenchmark {
    static func foundation(_ path: String) -> DirectoryMeasurement {
        var result = DirectoryMeasurement()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey]
        guard let iterator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys),
            errorHandler: { url, error in
                result.errorCount += 1
                result.firstError = result.firstError ?? "\(url.path): \(error.localizedDescription)"
                return true
            }
        ) else { result.errorCount += 1; return result }
        for case let url as URL in iterator {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isRegularFile == true {
                    result.files += 1
                    result.bytes += Int64((values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) / max(1, values.linkCount ?? 1))
                }
            } catch { result.errorCount += 1 }
        }
        return result
    }

    static func emit(_ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func main() throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            fputs("Usage: scan-benchmark /absolute/directory [other-disjoint-directory ...]\n", stderr)
            exit(2)
        }
        let info = ProcessInfo.processInfo
        let iterations = max(1, Int(info.environment["BENCH_RUNS"] ?? "7") ?? 7)
        try emit(["type": "environment", "os": info.operatingSystemVersionString,
                  "cores": info.activeProcessorCount, "memory": info.physicalMemory,
                  "lowPower": info.isLowPowerModeEnabled, "thermal": info.thermalState.rawValue,
                  "roots": paths, "note": "Alternating order; runs share filesystem caches. No cold-cache or energy claim."])
        var reference: (Int, Int64)?
        for run in 0..<iterations {
            let modes = run.isMultiple(of: 2) ? ["foundation", "fts", "fts-parallel"] : ["fts-parallel", "fts", "foundation"]
            for mode in modes {
                let start = DispatchTime.now().uptimeNanoseconds
                let results = ScanResults<DirectoryMeasurement>()
                let workers = mode == "fts-parallel" ? ScanResourcePolicy.current.workers : 1
                let queue = OperationQueue()
                queue.qualityOfService = .utility
                queue.maxConcurrentOperationCount = workers
                for path in paths {
                    queue.addOperation {
                        results.append(mode == "foundation" ? foundation(path) : DirectoryMeasurement.measure(path: path))
                    }
                }
                queue.waitUntilAllOperationsAreFinished()
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                let values = results.snapshot()
                let count = values.reduce(0) { $0 + $1.files }
                let bytes = values.reduce(Int64(0)) { $0 + $1.bytes }
                let errors = values.reduce(0) { $0 + $1.errorCount }
                if reference == nil { reference = (count, bytes) }
                let matches = reference!.0 == count && reference!.1 == bytes && errors == 0
                try emit(["type": "sample", "run": run, "mode": mode, "seconds": seconds,
                          "files": count, "bytes": bytes, "errors": errors, "workers": workers,
                          "matchesReference": matches, "filesPerSecond": Double(count) / seconds])
                if !matches {
                    fputs("Counts/bytes differ or scan failed; performance comparison is invalid.\n", stderr)
                    exit(1)
                }
            }
        }
    }
}
