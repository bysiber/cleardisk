import Foundation

enum CacheSection: String, CaseIterable {
    case app
    case developer

    var title: String {
        switch self {
        case .app: return L("App Caches")
        case .developer: return L("Developer Caches")
        }
    }

    var subtitle: String {
        switch self {
        case .app: return L("Browsers, communication, media, and installed apps")
        case .developer: return L("IDEs, package managers, build tools, and local models")
        }
    }
}

struct CacheSafetyDetails {
    let removes: String
    let keeps: String
    let note: String

    init(removes: String, keeps: String, note: String) {
        self.removes = L(removes)
        self.keeps = L(keeps)
        self.note = L(note)
    }
}

struct CachePathDefinition {
    /// Display name, localized for the user's language.
    let name: String
    /// The English name exactly as declared. Logic that recognizes a specific cache must
    /// compare against this, never against `name`, which changes with the language.
    let rawName: String
    let icon: String
    let path: String
    let riskLevel: String
    let group: String?
    let section: CacheSection
    let description: String
    let safetyDetails: CacheSafetyDetails?

    init(
        name: String,
        icon: String,
        path: String,
        riskLevel: String,
        group: String?,
        section: CacheSection,
        description: String,
        safetyDetails: CacheSafetyDetails? = nil
    ) {
        self.name = L(name)
        self.rawName = name
        self.icon = icon
        self.path = path
        self.riskLevel = riskLevel
        self.group = group
        self.section = section
        self.description = L(description)
        self.safetyDetails = safetyDetails
    }
}

/// Curated consumer-app caches are isolated from the developer registry. Broad profile and
/// Application Support roots are forbidden here. When an app is detected but its cache contents
/// are not curated, it is surfaced as caution and never enters one-click safe cleanup.
enum AppCacheCatalog {
    static func definitions(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        excludingPaths: Set<String> = []
    ) -> [CachePathDefinition] {
        let curated = curatedDefinitions(home: home)
        let reservedPaths = excludingPaths.union(curated.map(\.path))
        let appNames = installedAppNames()
        let sparkleUpdates = sparkleUpdateDefinitions(home: home, excludingPaths: reservedPaths, appNames: appNames)
        let shipItUpdates = shipItUpdateDefinitions(
            home: home,
            excludingPaths: reservedPaths.union(sparkleUpdates.map(\.path)),
            appNames: appNames
        )
        let updates = sparkleUpdates + shipItUpdates
        let allReservedPaths = reservedPaths.union(updates.map(\.path))
        return curated
            + updates
            + discoveredInstalledAppCaches(home: home, excludingPaths: allReservedPaths, appNames: appNames)
    }

    private static func curatedDefinitions(home: String) -> [CachePathDefinition] {
        let browserImpact = CacheSafetyDetails(
            removes: "Cached copies of pages, images, scripts, generated code, and media.",
            keeps: "Cookies, logins, passwords, bookmarks, history, extensions, profiles, and open tabs.",
            note: "Quit the browser first. The first launch and first page loads may be slower."
        )
        let electronImpact = CacheSafetyDetails(
            removes: "Only the listed HTTP, generated-code, network, or graphics cache directory.",
            keeps: "Accounts, messages, cookies, local storage, settings, and documents.",
            note: "Quit the app first so it can rebuild these files cleanly."
        )
        let nativeAppImpact = CacheSafetyDetails(
            removes: "Temporary resources stored in the app's macOS cache container.",
            keeps: "The app bundle, Documents, and Application Support locations are not targeted.",
            note: "Quit the app and review in Finder first; some apps misuse their cache container."
        )

        return [
            // Browsers: profile data lives outside these macOS cache roots.
            app("Google Chrome", "globe", "\(home)/Library/Caches/Google/Chrome", "Browsers", "Cached Chrome web resources; browser profile data is not targeted.", browserImpact),
            app("Chrome Canary", "globe", "\(home)/Library/Caches/Google/Chrome Canary", "Browsers", "Cached Chrome Canary web resources; browser profile data is not targeted.", browserImpact),
            app("Chromium", "globe", "\(home)/Library/Caches/Chromium", "Browsers", "Cached Chromium web resources; browser profile data is not targeted.", browserImpact),
            app("Firefox", "flame.fill", "\(home)/Library/Caches/Firefox", "Browsers", "Firefox web, startup, thumbnail, and safe-browsing caches.", browserImpact),
            app("Firefox Developer Edition", "flame.fill", "\(home)/Library/Caches/Firefox Developer Edition", "Browsers", "Firefox Developer Edition cache files only.", browserImpact),
            app("Firefox Update Download", "arrow.down.app.fill", "\(home)/Library/Caches/Mozilla/updates", "App Updates", "Downloaded Firefox update payloads and updater state.", CacheSafetyDetails(removes: "Downloaded or partially staged Firefox update files.", keeps: "Firefox, profiles, bookmarks, passwords, history, open tabs, and settings.", note: "Quit Firefox first. Firefox may download the update again."), riskLevel: "caution"),
            app("Safari", "safari.fill", "\(home)/Library/Caches/com.apple.Safari", "Browsers", "Safari's macOS cache container; website data is stored separately.", browserImpact),
            app("Microsoft Edge", "globe", "\(home)/Library/Caches/Microsoft Edge", "Browsers", "Cached Edge web resources; browser profile data is not targeted.", browserImpact),
            app("Microsoft Edge Beta", "globe", "\(home)/Library/Caches/Microsoft Edge Beta", "Browsers", "Cached Edge Beta web resources; browser profile data is not targeted.", browserImpact),
            app("Microsoft Edge Dev", "globe", "\(home)/Library/Caches/Microsoft Edge Dev", "Browsers", "Cached Edge Dev web resources; browser profile data is not targeted.", browserImpact),
            app("Brave", "shield.fill", "\(home)/Library/Caches/BraveSoftware/Brave-Browser", "Browsers", "Cached Brave web resources; browser profile data is not targeted.", browserImpact),
            app("Brave Beta", "shield.fill", "\(home)/Library/Caches/BraveSoftware/Brave-Browser-Beta", "Browsers", "Cached Brave Beta web resources; browser profile data is not targeted.", browserImpact),
            app("Brave Nightly", "shield.fill", "\(home)/Library/Caches/BraveSoftware/Brave-Browser-Nightly", "Browsers", "Cached Brave Nightly web resources; browser profile data is not targeted.", browserImpact),
            app("Arc", "globe", "\(home)/Library/Caches/company.thebrowser.Browser", "Browsers", "Arc's macOS cache container; spaces and profiles are not targeted.", browserImpact),
            app("Opera", "globe", "\(home)/Library/Caches/com.operasoftware.Opera", "Browsers", "Cached Opera web resources; browser profile data is not targeted.", browserImpact),
            app("Vivaldi", "globe", "\(home)/Library/Caches/Vivaldi", "Browsers", "Cached Vivaldi web resources; browser profile data is not targeted.", browserImpact),

            // Electron roots are split into exact cache folders; cookies and local storage are siblings.
            app("Discord Native Cache", "bubble.left.and.bubble.right.fill", "\(home)/Library/Caches/com.hnc.Discord", "Communication", "Discord's macOS-native temporary resource cache.", nativeAppImpact, riskLevel: "caution"),
            app("Discord Web Cache", "bubble.left.and.bubble.right.fill", "\(home)/Library/Application Support/discord/Cache", "Communication", "Discord HTTP cache only.", electronImpact),
            app("Discord Code Cache", "chevron.left.forwardslash.chevron.right", "\(home)/Library/Application Support/discord/Code Cache", "Communication", "Generated JavaScript and WebAssembly cache only.", electronImpact),
            app("Discord GPU Cache", "display", "\(home)/Library/Application Support/discord/GPUCache", "Communication", "Disposable graphics cache only.", electronImpact),
            app("Slack Native Cache", "number", "\(home)/Library/Caches/com.tinyspeck.slackmacgap", "Communication", "Slack's macOS-native temporary resource cache.", nativeAppImpact, riskLevel: "caution"),
            app("Slack Web Cache", "number", "\(home)/Library/Application Support/Slack/Cache", "Communication", "Slack HTTP cache only.", electronImpact),
            app("Slack Code Cache", "chevron.left.forwardslash.chevron.right", "\(home)/Library/Application Support/Slack/Code Cache", "Communication", "Slack generated-code cache only.", electronImpact),
            app("Slack GPU Cache", "display", "\(home)/Library/Application Support/Slack/GPUCache", "Communication", "Slack graphics cache only.", electronImpact),
            app("Slack App Store Cache", "number", "\(home)/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches", "Communication", "Slack App Store cache container.", nativeAppImpact, riskLevel: "caution"),
            app("Zoom", "video.fill", "\(home)/Library/Caches/us.zoom.xos", "Communication", "Zoom's macOS cache container.", nativeAppImpact, riskLevel: "caution"),
            app("Microsoft Teams", "person.3.fill", "\(home)/Library/Caches/com.microsoft.teams2", "Communication", "New Teams' macOS cache container.", nativeAppImpact, riskLevel: "caution"),
            app("WhatsApp", "phone.fill", "\(home)/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches", "Communication", "WhatsApp's sandbox cache container.", nativeAppImpact, riskLevel: "caution"),
            app("Signal Web Cache", "message.fill", "\(home)/Library/Application Support/Signal/Cache", "Communication", "Signal HTTP cache only.", electronImpact),
            app("Signal Code Cache", "chevron.left.forwardslash.chevron.right", "\(home)/Library/Application Support/Signal/Code Cache", "Communication", "Signal generated-code cache only.", electronImpact),
            app("Signal GPU Cache", "display", "\(home)/Library/Application Support/Signal/GPUCache", "Communication", "Signal graphics cache only.", electronImpact),

            // Media and games. Offline libraries and installed games are deliberately excluded.
            app("Spotify", "music.note", "\(home)/Library/Caches/com.spotify.client", "Media & Games", "Streamed music and podcast cache; offline downloads are stored separately.", CacheSafetyDetails(removes: "Previously streamed temporary audio and artwork.", keeps: "Your account, playlists, local files, and explicitly downloaded offline library.", note: "Quit Spotify first. Streamed content may use bandwidth again.")),
            app("Spotify Helper", "music.note", "\(home)/Library/Caches/com.spotify.client.helper", "Media & Games", "Spotify helper-process cache.", nativeAppImpact, riskLevel: "caution"),
            app("VLC", "play.rectangle.fill", "\(home)/Library/Caches/org.videolan.vlc", "Media & Games", "VLC's macOS cache container.", nativeAppImpact, riskLevel: "caution"),
            app("Steam Web Cache", "gamecontroller.fill", "\(home)/Library/Caches/Steam/config/htmlcache", "Media & Games", "Steam store, community, and library web-interface cache.", electronImpact),
            app("Steam Legacy Web Cache", "gamecontroller.fill", "\(home)/Library/Application Support/Steam/config/htmlcache", "Media & Games", "Steam's alternate web-interface cache location.", electronImpact),
            app("Stremio Network Cache", "play.tv.fill", "\(home)/Library/Caches/com.westbridge.stremio5-mac/WebKit/NetworkCache", "Media & Games", "Stremio network cache; streams and account data are not targeted.", electronImpact),

            // Productivity and creative apps. Only exact cache subfolders are listed.
            app("Raycast Web Cache", "command", "\(home)/Library/Caches/com.raycast.macos/urlcache", "Productivity", "Raycast Store and API response cache. Clipboard history is explicitly excluded.", CacheSafetyDetails(removes: "Raycast Store, API, and web-response cache.", keeps: "Clipboard history, extensions, preferences, snippets, and account data.", note: "Quit Raycast first. ClearDisk never targets the sibling Clipboard folder.")),
            app("Obsidian Web Cache", "doc.text.fill", "\(home)/Library/Application Support/obsidian/Cache", "Productivity", "Obsidian HTTP cache only; vaults and metadata storage are not targeted.", electronImpact),
            app("Obsidian Code Cache", "chevron.left.forwardslash.chevron.right", "\(home)/Library/Application Support/obsidian/Code Cache", "Productivity", "Obsidian generated-code cache only.", electronImpact),
            app("Obsidian GPU Cache", "display", "\(home)/Library/Application Support/obsidian/GPUCache", "Productivity", "Obsidian graphics cache only.", electronImpact),
            app("Notion Web Cache", "doc.richtext.fill", "\(home)/Library/Application Support/Notion/Cache", "Productivity", "Notion HTTP cache only.", electronImpact),
            app("Notion Code Cache", "chevron.left.forwardslash.chevron.right", "\(home)/Library/Application Support/Notion/Code Cache", "Productivity", "Notion generated-code cache only.", electronImpact),
            app("Notion GPU Cache", "display", "\(home)/Library/Application Support/Notion/GPUCache", "Productivity", "Notion graphics cache only.", electronImpact),
            app("GitHub Desktop Web Cache", "chevron.left.forwardslash.chevron.right", "\(home)/Library/Application Support/GitHub Desktop/Cache", "Productivity", "GitHub Desktop HTTP cache only; repositories are not targeted.", electronImpact),
            app("Codex Web Cache", "bubble.right.fill", "\(home)/Library/Caches/Codex/Default/Cache", "Productivity", "Codex HTTP cache only; task and account data are not targeted.", electronImpact),
            app("Codex Browser Cache", "globe", "\(home)/Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache", "Productivity", "HTTP cache for Codex's isolated browser partition.", CacheSafetyDetails(removes: "Cached browser responses used by Codex.", keeps: "Codex tasks, accounts, settings, browser cookies, and downloaded files.", note: "Quit Codex first. Browser content may load more slowly once while the cache rebuilds.")),
            app("Bambu Studio Web Cache", "cube.fill", "\(home)/Library/Caches/com.bambulab.bambu-studio/WebKit/NetworkCache", "Creative Apps", "Bambu Studio's embedded web cache; projects and printer settings are not targeted.", electronImpact),
            app("Blender Cache", "cube.transparent.fill", "\(home)/Library/Caches/Blender", "Creative Apps", "Blender's macOS cache container; blend files and preferences are not targeted.", nativeAppImpact, riskLevel: "caution"),
            app("Asset Manager Thumbnails", "photo.on.rectangle.angled", "\(home)/Library/Caches/Asset Manager/Asset Thumbnails", "Creative Apps", "Generated previews for assets; original asset files are not targeted.", CacheSafetyDetails(removes: "Generated asset preview images.", keeps: "Original assets, projects, imported files, and app settings.", note: "The app may regenerate thumbnails the next time those assets are viewed.")),
            app("Asset Manager Model Thumbnails", "cube.transparent", "\(home)/Library/Caches/Asset Manager/Model Thumbnails", "Creative Apps", "Generated model preview images; source models are not targeted.", CacheSafetyDetails(removes: "Generated model preview images.", keeps: "Original models, textures, projects, and app settings.", note: "The app may regenerate model thumbnails on demand.")),
            app("Asset Manager Adapted Models", "cube.fill", "\(home)/Library/Caches/Asset Manager/Adapted Models", "Creative Apps", "Generated model variants used for faster previews or compatibility.", CacheSafetyDetails(removes: "Derived model copies and their generated textures.", keeps: "Original imported models, projects, and app settings.", note: "Review first: rebuilding adapted models may take time."), riskLevel: "caution")
        ]
    }

    private static func app(
        _ name: String,
        _ icon: String,
        _ path: String,
        _ group: String,
        _ description: String,
        _ safetyDetails: CacheSafetyDetails,
        riskLevel: String = "safe"
    ) -> CachePathDefinition {
        CachePathDefinition(name: name, icon: icon, path: path, riskLevel: riskLevel, group: group, section: .app, description: description, safetyDetails: safetyDetails)
    }

    /// Sparkle can retain entire downloaded app updates. Recoverable, but potentially expensive.
    private static func sparkleUpdateDefinitions(home: String, excludingPaths: Set<String>, appNames: [String: String]) -> [CachePathDefinition] {
        let cacheRoot = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches", isDirectory: true)
        let fm = FileManager.default
        guard let roots = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return roots.compactMap { root in
            let path = root.appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true).path
            guard fm.fileExists(atPath: path), !isCovered(path, by: excludingPaths) else { return nil }
            let appName = appNames[root.lastPathComponent] ?? readableBundleName(root.lastPathComponent)
            return app(String(format: L("%@ Update Download"), appName), "arrow.down.app.fill", path, "App Updates", "Downloaded Sparkle update payloads and installer staging files.", CacheSafetyDetails(removes: "A downloaded or partially staged app update.", keeps: "The installed app, its settings, accounts, and documents.", note: "Review first: the app may need to download the update again."), riskLevel: "caution")
        }
    }

    /// Squirrel.Mac stores downloaded and staged updates beside logs and ShipIt state in
    /// ~/Library/Caches/<bundle-id>.ShipIt. They are recoverable downloads, but removing an active
    /// staging directory can interrupt an update, so every match remains review-only.
    private static func shipItUpdateDefinitions(home: String, excludingPaths: Set<String>, appNames: [String: String]) -> [CachePathDefinition] {
        let cacheRoot = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches", isDirectory: true)
        let fm = FileManager.default
        guard let roots = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }

        return roots.compactMap { root in
            let folderName = root.lastPathComponent
            guard folderName.hasSuffix(".ShipIt"), !isCovered(root.path, by: excludingPaths) else { return nil }

            let bundleID = String(folderName.dropLast(".ShipIt".count))
            let appName = appNames[bundleID] ?? readableBundleName(bundleID)
            return app(
                String(format: L("%@ Update Staging"), appName),
                "arrow.down.app.fill",
                root.path,
                "App Updates",
                "Downloaded or staged Squirrel updater files.",
                CacheSafetyDetails(
                    removes: "The downloaded update payload, staging copy, updater state, and updater logs.",
                    keeps: "The currently installed app, its settings, accounts, and documents.",
                    note: "Quit the app first. Do not clean while an update is installing; the update may need to download again."
                ),
                riskLevel: "caution"
            )
        }
    }

    /// Detect installed apps without declaring opaque cache containers safe. These are review-only.
    private static func discoveredInstalledAppCaches(home: String, excludingPaths: Set<String>, appNames: [String: String]) -> [CachePathDefinition] {
        let fm = FileManager.default
        return appNames.compactMap { bundleID, appName in
            guard !bundleID.hasPrefix("com.apple.") else { return nil }
            let candidates = ["\(home)/Library/Caches/\(bundleID)", "\(home)/Library/Containers/\(bundleID)/Data/Library/Caches"]
            guard let path = candidates.first(where: { fm.fileExists(atPath: $0) && !isCovered($0, by: excludingPaths) }) else { return nil }
            return app(appName, "app.fill", path, "Other Installed Apps", "Detected macOS cache container; its internal layout is not curated by ClearDisk.", CacheSafetyDetails(removes: "Everything this app currently stores in its designated cache container.", keeps: "The app bundle, Documents, and Application Support locations are not targeted.", note: "Review in Finder first. Some apps misuse cache folders, so this is never auto-selected."), riskLevel: "caution")
        }
    }

    private static func installedAppNames() -> [String: String] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        var result: [String: String] = [:]
        for root in roots {
            guard let apps = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for appURL in apps where appURL.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: appURL), let identifier = bundle.bundleIdentifier else { continue }
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent
                result[identifier] = displayName
            }
        }
        return result
    }

    private static func isCovered(_ path: String, by reservedPaths: Set<String>) -> Bool {
        reservedPaths.contains { reserved in path == reserved || path.hasPrefix(reserved + "/") || reserved.hasPrefix(path + "/") }
    }

    private static func readableBundleName(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "-", with: " ").capitalized ?? "App"
    }
}
