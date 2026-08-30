import Cocoa
import SwiftUI
import UserNotifications
import Combine
import Sparkle

// MARK: - App Entry Point
@main
struct ClearDiskApp {
    /// `NSApplication.delegate` is a **weak** reference (NSApplication.h: `@property (nullable, weak)`),
    /// and nothing else in this app retains the delegate — the Combine sink, the refresh timer and the
    /// event monitor all capture it weakly. Held only by a local in `main()`, ARC is free to release it
    /// after its last use, which is the assignment below — i.e. before or during `app.run()`.
    ///
    /// When that happens the delegate takes the status item and the popover down with it: the process
    /// stays alive but there is no menu bar icon and nothing responds to clicks. Whether it happens at
    /// all depends on the optimiser, so it reproduces on some Macs and not others (#16, #22).
    ///
    /// A static holds it for the life of the process.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Menu bar only, no dock icon
        app.run()
    }
}

/// The app's identity, read back from the bundle that `scripts/build_app.sh` generates.
/// The version is declared exactly once — in CHANGELOG.md — so the UI can never disagree with the
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
    var diskSpaceStore: DiskSpaceStore!
    var primaryModePanelController: PrimaryModePanelController!
    var diskSpaceWindowController: DiskSpaceWindowController!
    var eventMonitor: Any?
    var cancellables = Set<AnyCancellable>()

    /// Sparkle owns the complete update UI and installation flow. Keep the controller alive for
    /// the process lifetime; a local `swift run` build has no app Info.plist, so updater startup is
    /// intentionally skipped there while packaged ClearDisk.app builds use the configured feed.
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        diskMonitor = DiskMonitor()
        diskSpaceStore = DiskSpaceStore()
        primaryModePanelController = PrimaryModePanelController(
            diskMonitor: diskMonitor,
            onOpenDiskSpace: { [weak self] in
                self?.openDiskSpaceWindow()
            }
        )
        diskSpaceWindowController = DiskSpaceWindowController(
            diskMonitor: diskMonitor,
            store: diskSpaceStore
        )
        diskMonitor.checkNotificationStatus()
        diskMonitor.loadCleanupTotals()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            updateMenuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
            // The default mouse-up action can arrive after a transient popover has already closed,
            // causing togglePopover() to immediately reopen it. Handle the initial mouse-down so
            // the second click observes the still-open state and closes it deterministically.
            button.sendAction(on: [.leftMouseDown])
        }
        
        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: Layout.popoverWidth, height: Layout.popoverHeight)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MainView(
                diskMonitor: diskMonitor,
                diskSpaceStore: diskSpaceStore,
                checkForUpdates: { [weak self] in
                    self?.checkForUpdates()
                },
                showDiskSpaceWindow: { [weak self] in
                    self?.openDiskSpaceWindow()
                }
            )
        )

        // Initialize after the app bundle and delegate are fully ready. Sparkle schedules future
        // checks from SUEnableAutomaticChecks and SUScheduledCheckInterval in Info.plist.
        _ = updaterController
        
        // Capacity is safe to read without touching protected folders. A recursive scan starts
        // only after the installed app identity has Full Disk Access, avoiding a cascade of
        // Desktop, Documents, Downloads, Photos, Media and App Data permission dialogs.
        diskMonitor.refreshDiskSpaceOnly()
        diskMonitor.checkFullDiskAccess { [weak self] granted in
            guard let self, granted else { return }
            self.diskMonitor.markOnboardingComplete()
            self.diskMonitor.scan()
        }
        
        // Auto-update menu bar when disk data changes
        diskMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        // One timer avoids a light refresh and a full scan racing each other at the 30-minute mark.
        // Five ticks perform only a cheap APFS capacity lookup; every sixth tick refreshes all
        // results. The full scan also refreshes capacity, so no separate lookup is needed then.
        var refreshTick = 0
        Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            refreshTick += 1
            if refreshTick == 6 {
                refreshTick = 0
                if self?.diskMonitor.fullDiskAccess == .granted {
                    self?.diskMonitor.scan()
                } else {
                    self?.diskMonitor.refreshDiskSpaceOnly()
                }
            } else {
                self?.diskMonitor.refreshDiskSpaceOnly()
            }
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
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                diskMonitor.checkFullDiskAccess { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.diskMonitor.markOnboardingComplete()
                        self.diskMonitor.scanIfStale()
                    } else {
                        self.diskMonitor.refreshDiskSpaceOnly()
                    }
                }

                // An .accessory app never becomes active on its own, so the popover opens as an
                // INACTIVE window — macOS then renders its vibrancy washed out and the text is hard
                // to read until the first click makes it key. Activate and take key up front so the
                // popover looks the same the moment it appears as it does after you click it.
                NSApp.activate(ignoringOtherApps: true)
                popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)

                // NSPopover clips everything to its own bounds. The primary modes live in a small
                // child panel so they can sit outside the left edge without widening or covering
                // the 380-point cleaner UI.
                DispatchQueue.main.async { [weak self] in
                    guard
                        let self,
                        self.popover.isShown,
                        let contentView = self.popover.contentViewController?.view,
                        let popoverWindow = contentView.window
                    else { return }
                    self.primaryModePanelController.show(
                        attachedTo: popoverWindow,
                        alignedTo: contentView
                    )
                }


                // Close popover on outside click
                eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    self?.closePopover()
                }
            }
        }
    }
    
    private func closePopover() {
        // A child NSPanel can keep its parent popover alive. Detach it before asking AppKit to
        // close so a second click on the menu-bar item always toggles the entire UI off.
        primaryModePanelController.hide()
        popover.close()
    }

    @MainActor
    private func openDiskSpaceWindow() {
        guard diskMonitor.fullDiskAccess == .granted,
              diskSpaceStore.trashAlert == nil,
              diskSpaceStore.deletingNodeIDs.isEmpty else {
            return
        }
        closePopover()
        DispatchQueue.main.async { [weak self] in
            self?.diskSpaceWindowController.show()
        }
    }

    private func checkForUpdates() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(nil)
    }

    /// Covers every way the popover can go away, including the transient auto-close on focus loss.
    func popoverDidClose(_ notification: Notification) {
        primaryModePanelController.hide()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        NotificationCenter.default.post(name: .clearDiskPopoverDidClose, object: nil)
    }
}
