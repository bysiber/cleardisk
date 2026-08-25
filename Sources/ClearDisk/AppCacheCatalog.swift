import Foundation

enum CacheSection: String, CaseIterable {
    case app
    case developer

    var title: String {
        switch self {
        case .app: return "App Caches"
        case .developer: return "Developer Caches"
        }
    }

    var badge: String {
        switch self {
        case .app: return "APPS"
        case .developer: return "DEVELOPER"
        }
    }
}

struct CachePathDefinition {
    let name: String
    let icon: String
    let path: String
    let riskLevel: String
    let group: String?
    let section: CacheSection
    let description: String
}

/// User-facing application caches are deliberately isolated from the developer cache registry.
/// Every entry must remain a narrow, disposable directory under `~/Library/Caches`; never add a
/// browser profile or a broad Application Support directory that may contain user data.
enum AppCacheCatalog {
    static func definitions(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [CachePathDefinition] {
        let browserDescription = "Temporary website resources. History, bookmarks, passwords, cookies, and open tabs are not stored here."
        let appDescription = "Temporary app resources that are recreated automatically. Accounts, messages, settings, and documents are not touched."

        return [
            // Browsers
            CachePathDefinition(name: "Google Chrome", icon: "globe", path: "\(home)/Library/Caches/Google/Chrome", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Firefox", icon: "flame.fill", path: "\(home)/Library/Caches/Firefox", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Safari", icon: "safari.fill", path: "\(home)/Library/Caches/com.apple.Safari", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Microsoft Edge", icon: "globe", path: "\(home)/Library/Caches/Microsoft Edge", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Brave", icon: "shield.fill", path: "\(home)/Library/Caches/BraveSoftware/Brave-Browser", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Arc", icon: "globe", path: "\(home)/Library/Caches/company.thebrowser.Browser", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Opera", icon: "globe", path: "\(home)/Library/Caches/com.operasoftware.Opera", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),
            CachePathDefinition(name: "Vivaldi", icon: "globe", path: "\(home)/Library/Caches/Vivaldi", riskLevel: "safe", group: "Browsers", section: .app, description: browserDescription),

            // Communication
            CachePathDefinition(name: "Discord", icon: "bubble.left.and.bubble.right.fill", path: "\(home)/Library/Caches/com.hnc.Discord", riskLevel: "safe", group: "Communication", section: .app, description: appDescription),
            CachePathDefinition(name: "Slack", icon: "number", path: "\(home)/Library/Caches/com.tinyspeck.slackmacgap", riskLevel: "safe", group: "Communication", section: .app, description: appDescription),
            CachePathDefinition(name: "Zoom", icon: "video.fill", path: "\(home)/Library/Caches/us.zoom.xos", riskLevel: "safe", group: "Communication", section: .app, description: appDescription),
            CachePathDefinition(name: "Microsoft Teams", icon: "person.3.fill", path: "\(home)/Library/Caches/com.microsoft.teams2", riskLevel: "safe", group: "Communication", section: .app, description: appDescription),

            // Media and game clients
            CachePathDefinition(name: "Spotify", icon: "music.note", path: "\(home)/Library/Caches/com.spotify.client", riskLevel: "safe", group: "Media & Games", section: .app, description: appDescription),
            CachePathDefinition(name: "VLC", icon: "play.rectangle.fill", path: "\(home)/Library/Caches/org.videolan.vlc", riskLevel: "safe", group: "Media & Games", section: .app, description: appDescription),
            CachePathDefinition(name: "Steam Web Cache", icon: "gamecontroller.fill", path: "\(home)/Library/Caches/com.valvesoftware.steam.helper", riskLevel: "safe", group: "Media & Games", section: .app, description: "Temporary Steam store and community web resources. Installed games, saves, and downloads are not touched.")
        ]
    }
}
