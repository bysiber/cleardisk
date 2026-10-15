import Darwin
import Foundation

struct TemporaryFilesScanSource: Sendable {
    let name: String
    let url: URL
}

struct TemporaryFilesScanGroup: Sendable {
    let name: String
    let url: URL
    let sources: [TemporaryFilesScanSource]
}

enum TemporaryFilesScanPlan {
    static func make(fileManager: FileManager = .default) -> [TemporaryFilesScanGroup] {
        let userTemporaryURL = canonicalURL(fileManager.temporaryDirectory)
        let sharedTemporaryURL = canonicalURL(
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let persistentTemporaryURL = canonicalURL(
            URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
        )

        var groups = [
            singleSourceGroup(
                name: L("User Temporary Files"),
                sourceName: L("Current User"),
                url: userTemporaryURL,
                fileManager: fileManager
            ),
            singleSourceGroup(
                name: L("Shared Temporary Files"),
                sourceName: "Shared",
                url: sharedTemporaryURL,
                fileManager: fileManager
            ),
            singleSourceGroup(
                name: L("Persistent Temporary Files"),
                sourceName: "Persistent",
                url: persistentTemporaryURL,
                fileManager: fileManager
            )
        ].compactMap { $0 }

        let sandboxSources = sandboxTemporarySources(fileManager: fileManager)
        if !sandboxSources.isEmpty {
            groups.append(
                TemporaryFilesScanGroup(
                    name: L("Sandboxed App Temporary Files"),
                    url: fileManager.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Containers", isDirectory: true),
                    sources: sandboxSources
                )
            )
        }

        return groups
    }

    private static func singleSourceGroup(
        name: String,
        sourceName: String,
        url: URL,
        fileManager: FileManager
    ) -> TemporaryFilesScanGroup? {
        guard isDirectory(url, fileManager: fileManager) else { return nil }
        return TemporaryFilesScanGroup(
            name: name,
            url: url,
            sources: [TemporaryFilesScanSource(name: sourceName, url: url)]
        )
    }

    private static func sandboxTemporarySources(
        fileManager: FileManager
    ) -> [TemporaryFilesScanSource] {
        let containersURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        guard let containerURLs = try? fileManager.contentsOfDirectory(
            at: containersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var seenPaths = Set<String>()
        return containerURLs.compactMap { containerURL in
            let temporaryURL = canonicalURL(
                containerURL
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
            )
            guard isDirectory(temporaryURL, fileManager: fileManager),
                  directoryHasContents(temporaryURL, fileManager: fileManager),
                  seenPaths.insert(temporaryURL.path).inserted else { return nil }

            return TemporaryFilesScanSource(
                name: sandboxDisplayName(containerURL.lastPathComponent),
                url: temporaryURL
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func directoryHasContents(_ url: URL, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return !contents.isEmpty
    }

    private static func sandboxDisplayName(_ containerIdentifier: String) -> String {
        containerIdentifier
            .split(separator: ".")
            .last
            .map(String.init)
            ?? containerIdentifier
    }

    private static func canonicalURL(_ url: URL) -> URL {
        let resolvedPath = url.withUnsafeFileSystemRepresentation { fileSystemPath -> String? in
            guard let fileSystemPath,
                  let canonicalPath = Darwin.realpath(fileSystemPath, nil) else { return nil }
            defer { Darwin.free(canonicalPath) }
            return String(cString: canonicalPath)
        }
        guard let resolvedPath else { return url.standardizedFileURL }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
    }
}
