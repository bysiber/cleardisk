import AppKit
import SwiftUI

// MARK: - Welcome Window Controller
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    var onDismiss: (() -> Void)?
    private var isDismissed = false

    init(diskMonitor: DiskMonitor, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("Welcome to ClearDisk")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        super.init()

        let rootView = WelcomeView(diskMonitor: diskMonitor) { [weak self] in
            self?.dismiss()
        }
        window.contentViewController = NSHostingController(rootView: rootView)
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    private func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        close()
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isDismissed else { return }
        isDismissed = true
        onDismiss?()
    }
}

// MARK: - Welcome View
struct WelcomeView: View {
    @ObservedObject var diskMonitor: DiskMonitor
    let onDismiss: () -> Void
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    private var freeSpaceString: String {
        let freeGB = Double(diskMonitor.freeSpace) / 1_073_741_824
        if freeGB >= 1.0 {
            return " \(String(format: "%.0f", freeGB))GB"
        }
        let freeMB = Double(max(0, diskMonitor.freeSpace)) / 1_048_576
        return " \(String(format: "%.0f", freeMB))MB"
    }

    var body: some View {
        VStack(spacing: 18) {
            // Header
            HStack(spacing: 16) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 54)
                } else {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 42))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Welcome to ClearDisk"))
                        .font(.system(size: 22, weight: .bold))

                    Text(L("Developer cache cleaner & disk space monitor"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Menu Bar Mockup with pointer
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Finder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("File   Edit   View   Go   Window")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))

                    Spacer()

                    // Simulated system status icons
                    Image(systemName: "wifi")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Image(systemName: "battery.100")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    // ClearDisk Highlighted Status Item
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 10))
                        Text(freeSpaceString)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.accentColor, lineWidth: 1.5)
                            )
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(NSColor.controlBackgroundColor))
                )

                // Callout pointer to the menu bar item
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                        Text(L("ClearDisk lives here in your menu bar!"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.trailing, 6)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
            )

            // Info rows
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Runs in your Menu Bar"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(L("ClearDisk sits quietly in your menu bar without filling your Dock. Click its icon anytime to inspect caches and clean disk space."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("MacBook Notch & Hidden Icons"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(L("If your menu bar is crowded or hidden behind a camera notch, you can also launch ClearDisk from Finder or Spotlight anytime to open it."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            Spacer()

            // Footer action button
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text(L("Got it! Go to Menu Bar"))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 220, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 540, height: 470)
        .preferredColorScheme(appearance.colorScheme)
    }
}
