import Cocoa
import SwiftUI

enum PrimaryMode: String, CaseIterable {
    case cleaner
    case review
    case diskSpace

    var title: String {
        switch self {
        case .cleaner: return "Cleaner"
        case .review: return "Review"
        case .diskSpace: return "Disk Space"
        }
    }

    var icon: String {
        switch self {
        case .cleaner: return "sparkles"
        case .review: return "checklist"
        case .diskSpace: return "internaldrive"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .cleaner: return "Cleaner"
        case .review: return "Review suggestions"
        case .diskSpace: return "Disk space overview"
        }
    }
}

extension Notification.Name {
    static let clearDiskPrimaryModeRequested = Notification.Name("ClearDisk.primaryModeRequested")
}

private final class PrimaryModePanelState: ObservableObject {
    @Published var isExpanded = false
}

private struct PrimaryModePanelView: View {
    @ObservedObject var diskMonitor: DiskMonitor
    @ObservedObject var panelState: PrimaryModePanelState
    @AppStorage("primaryMode") private var primaryMode: PrimaryMode = .cleaner
    @State private var hoveredMode: PrimaryMode?

    let onHoverChanged: (Bool) -> Void

    private var hasReviewItems: Bool {
        !diskMonitor.devCaches.isEmpty
            || !diskMonitor.projectArtifacts.isEmpty
            || !diskMonitor.largeFiles.isEmpty
            || diskMonitor.trashSizeBytes > 0
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(PrimaryMode.allCases, id: \.self) { mode in
                Button {
                    primaryMode = mode
                    NotificationCenter.default.post(
                        name: .clearDiskPrimaryModeRequested,
                        object: mode.rawValue
                    )
                } label: {
                    HStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 13, weight: .medium))
                                .symbolRenderingMode(.monochrome)
                                .foregroundColor(primaryMode == mode ? .accentColor : .secondary)

                            if mode == .review && hasReviewItems {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .frame(width: 26, height: 26)

                        if panelState.isExpanded {
                            Text(mode.title)
                                .font(.system(size: 11, weight: primaryMode == mode ? .semibold : .regular))
                                .foregroundColor(primaryMode == mode ? .primary : .secondary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(
                        width: panelState.isExpanded ? 116 : 30,
                        height: 30,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                primaryMode == mode
                                    ? Color.accentColor.opacity(0.14)
                                    : hoveredMode == mode
                                        ? Color.primary.opacity(0.07)
                                        : Color.clear
                            )
                    }
                    .overlay {
                        if primaryMode == mode {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    hoveredMode = isHovered ? mode : nil
                }
                .help(mode.accessibilityLabel)
                .accessibilityLabel(mode.accessibilityLabel)
            }
        }
        .padding(3)
        .frame(
            width: panelState.isExpanded
                ? PrimaryModePanelController.expandedWidth
                : PrimaryModePanelController.collapsedWidth,
            height: PrimaryModePanelController.panelHeight,
            alignment: .trailing
        )
        .background(
            .regularMaterial,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 9,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 9,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 9,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        )
        .onHover { isHovered in
            if !isHovered {
                hoveredMode = nil
            }
            onHoverChanged(isHovered)
        }
        .disabled(diskMonitor.isFirstLaunch && !diskMonitor.hasCompletedFirstScan)
        .opacity(
            diskMonitor.isFirstLaunch && !diskMonitor.hasCompletedFirstScan
                ? 0.5
                : 1
        )
        .animation(.easeInOut(duration: 0.20), value: panelState.isExpanded)
        // The host window never resizes. The visible material surface grows leftward inside this
        // fixed frame, leaving its trailing seam permanently pinned to the popover.
        .frame(
            width: PrimaryModePanelController.expandedWidth,
            height: PrimaryModePanelController.panelHeight,
            alignment: .trailing
        )
    }
}

/// Hosts the primary navigation in a small non-activating child panel attached to the popover.
/// Keeping it in a separate window lets it sit genuinely outside the popover instead of reserving
/// an invisible gutter inside the app's 380-point content area.
final class PrimaryModePanelController {
    static let collapsedWidth: CGFloat = 36
    static let expandedWidth: CGFloat = 122
    static let panelHeight: CGFloat = 102

    private static let popoverOverlap: CGFloat = 1
    private static let verticalOffset: CGFloat = 42

    private let panelState = PrimaryModePanelState()
    private let panel: NSPanel
    private weak var parentWindow: NSWindow?
    private var pendingCollapse: DispatchWorkItem?

    init(diskMonitor: DiskMonitor) {
        panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.expandedWidth,
                height: Self.panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        panel.contentViewController = NSHostingController(
            rootView: PrimaryModePanelView(
                diskMonitor: diskMonitor,
                panelState: panelState,
                onHoverChanged: { [weak self] isHovered in
                    self?.handleHoverChanged(isHovered)
                }
            )
        )
    }

    func show(attachedTo popoverWindow: NSWindow, alignedTo contentView: NSView) {
        if parentWindow !== popoverWindow {
            if let parentWindow {
                parentWindow.removeChildWindow(panel)
            }
            parentWindow = popoverWindow
            popoverWindow.addChildWindow(panel, ordered: .above)
        }

        pendingCollapse?.cancel()
        pendingCollapse = nil
        panelState.isExpanded = false
        panel.level = popoverWindow.level

        // `_NSPopoverWindow.frame` includes transparent chrome around the visible popover. Anchor
        // to the hosted content's screen rect instead, otherwise the panel appears separated by
        // that invisible inset even when the mathematical gap is zero.
        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        let visibleContentFrame = popoverWindow.convertToScreen(contentRectInWindow)
        position(width: Self.expandedWidth, relativeTo: visibleContentFrame)
        panel.orderFront(nil)
    }

    func hide() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        panelState.isExpanded = false
        panel.orderOut(nil)
        if let parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        parentWindow = nil
    }

    private func handleHoverChanged(_ isHovered: Bool) {
        pendingCollapse?.cancel()
        pendingCollapse = nil

        if isHovered {
            guard !panelState.isExpanded else { return }
            withAnimation(.easeInOut(duration: 0.20)) {
                panelState.isExpanded = true
            }
        } else {
            scheduleCollapseCheck()
        }
    }

    /// Growing the SwiftUI hover surface can briefly rebuild its tracking area. Confirm the pointer
    /// really left the visible panel before collapsing, avoiding a rapid open/close loop.
    private func scheduleCollapseCheck() {
        pendingCollapse?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panelState.isExpanded else { return }

            if self.panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleCollapseCheck()
                return
            }

            self.pendingCollapse = nil
            withAnimation(.easeInOut(duration: 0.20)) {
                self.panelState.isExpanded = false
            }
        }

        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func position(width: CGFloat, relativeTo popoverFrame: NSRect) {
        let origin = NSPoint(
            x: popoverFrame.minX - width + Self.popoverOverlap,
            y: popoverFrame.midY - (Self.panelHeight / 2) + Self.verticalOffset
        )
        panel.setFrame(
            NSRect(
                origin: origin,
                size: NSSize(width: width, height: Self.panelHeight)
            ),
            display: true
        )
    }
}
