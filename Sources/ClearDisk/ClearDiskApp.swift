import Cocoa
import SwiftUI
import UserNotifications

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

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var diskMonitor: DiskMonitor!
    var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        diskMonitor = DiskMonitor()
        diskMonitor.setupNotifications()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            updateMenuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MainView(diskMonitor: diskMonitor)
        )
        
        // Start monitoring
        diskMonitor.scan()
        
        // Update periodically (5 min)
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.diskMonitor.scan()
            self?.updateMenuBarIcon()
        }
    }
    
    func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let pct = diskMonitor.usedPercentage
        let cleanable = diskMonitor.totalCleanable
        
        // Smart icon based on threshold
        let symbol: String
        let tintColor: NSColor
        
        if pct >= 90 {
            symbol = "externaldrive.fill.badge.exclamationmark"
            tintColor = .systemRed
        } else if pct >= 80 {
            symbol = "externaldrive.fill.badge.minus"
            tintColor = .systemOrange
        } else {
            symbol = "externaldrive.fill"
            tintColor = .secondaryLabelColor
        }
        
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClearDisk") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = (pct < 80) // Template for normal, colored for warnings
            button.image = configured
            if pct >= 80 {
                button.contentTintColor = tintColor
            } else {
                button.contentTintColor = nil
            }
        }
        
        // Smart text: show cleanable when disk is stressed, compact info otherwise
        if pct >= 80 && cleanable > 0 {
            let cleanGB = Double(cleanable) / 1_073_741_824
            if cleanGB >= 1.0 {
                button.title = " \(String(format: "%.0f", cleanGB))GB ♻️"
            } else {
                let cleanMB = Double(cleanable) / 1_048_576
                button.title = " \(String(format: "%.0f", cleanMB))MB ♻️"
            }
        } else {
            let freeGB = diskMonitor.freeSpace / 1_073_741_824
            button.title = " \(freeGB)GB"
        }
    }
    
    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            if let button = statusItem.button {
                diskMonitor.scan()
                updateMenuBarIcon()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                
                // Close popover on outside click
                eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    self?.closePopover()
                }
            }
        }
    }
    
    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
