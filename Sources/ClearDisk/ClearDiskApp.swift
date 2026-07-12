import Cocoa
import SwiftUI
import UserNotifications
import Combine

// MARK: - App Entry Point
@main
struct ClearDiskApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Menu bar only, no dock icon
        app.run()
    }
}

/// The app's identity, read back from the bundle that `scripts/build_app.sh` generates.
/// The version is declared exactly once — in build_app.sh — so the UI can never disagree with the
/// bundle. Running via `swift run` has no Info.plist, hence the "dev" fallback.
enum AppInfo {
    static let version: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    static let buildNumber: String =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    /// e.g. "v1.8.0"
    static var displayVersion: String { "v\(version)" }
}

extension Notification.Name {
    /// Fired whenever the popover closes — including the `.transient` auto-close that happens when
    /// the user clicks another app. The SwiftUI tree listens and tears down any open modal, so the
    /// popover can never come back with a stranded presentation blocking input.
    static let clearDiskPopoverDidClose = Notification.Name("ClearDisk.popoverDidClose")
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var diskMonitor: DiskMonitor!
    var eventMonitor: Any?
    var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        diskMonitor = DiskMonitor()
        diskMonitor.setupNotifications()
        diskMonitor.loadSavedTotal()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            updateMenuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: Layout.popoverWidth, height: Layout.popoverHeight)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MainView(diskMonitor: diskMonitor)
        )
        
        // Start monitoring
        diskMonitor.scan()
        
        // Auto-update menu bar when disk data changes
        diskMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)
        
        // Refresh periodically (5 min)
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.diskMonitor.scan()
        }
    }
    
    func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let pct = diskMonitor.usedPercentage
        
        // Smart icon based on threshold
        let symbol: String
        if pct >= 90 {
            symbol = "externaldrive.fill.badge.exclamationmark"
        } else if pct >= 80 {
            symbol = "externaldrive.fill.badge.minus"
        } else {
            symbol = "externaldrive.fill"
        }
        
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClearDisk") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            button.image = configured
        }
        
        // Always show free space in tray
        let freeGB = Double(diskMonitor.freeSpace) / 1_073_741_824
        if freeGB >= 1.0 {
            button.title = " \(String(format: "%.0f", freeGB))GB"
        } else {
            let freeMB = Double(diskMonitor.freeSpace) / 1_048_576
            button.title = " \(String(format: "%.0f", freeMB))MB"
        }
    }
    
    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            if let button = statusItem.button {
                diskMonitor.scan()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                // An .accessory app never becomes active on its own, so the popover opens as an
                // INACTIVE window — macOS then renders its vibrancy washed out and the text is hard
                // to read until the first click makes it key. Activate and take key up front so the
                // popover looks the same the moment it appears as it does after you click it.
                NSApp.activate(ignoringOtherApps: true)
                popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)


                // Close popover on outside click
                eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    self?.closePopover()
                }
            }
        }
    }
    
    private func closePopover() {
        popover.performClose(nil)
    }

    /// Covers every way the popover can go away, including the transient auto-close on focus loss.
    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        NotificationCenter.default.post(name: .clearDiskPopoverDidClose, object: nil)
    }
}
