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

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
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
        popover.contentSize = NSSize(width: 380, height: 700)
        popover.behavior = .transient
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
