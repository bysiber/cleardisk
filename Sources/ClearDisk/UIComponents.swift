import SwiftUI
import AppKit

// MARK: - Layout Constants
/// Spacing and size tokens for the menu-bar popover UI.
/// Named `Layout` intentionally — callers use `Layout.spacingDefault` etc.
enum Layout {
    static let popoverWidth: CGFloat = 380
    static let popoverHeight: CGFloat = 700
    static let sheetInset: CGFloat = 28
    static let sheetHeightInset: CGFloat = 72

    static let spacingTight: CGFloat = 4
    static let spacingDefault: CGFloat = 8
    static let spacingLoose: CGFloat = 20
    static let spacingRow: CGFloat = 8
    static let spacingSection: CGFloat = 16

    static let margin: CGFloat = 12
    static let nestedIndent: CGFloat = 36
    static let iconColumn: CGFloat = 24
    static let chipV: CGFloat = 2
    static let emptyTop: CGFloat = 40
    static let metadataSpacing: CGFloat = 1
    static let listDividerPadding: CGFloat = 8
    static let listDividerOpacity: CGFloat = 0.22
    static let sectionVertical: CGFloat = 10
    static let sizeColumnWidth: CGFloat = 65
    static let actionsColumnWidth: CGFloat = 38
}

// MARK: - Path helpers
enum PathDisplay {
    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func isExternalVolume(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/")
    }

    /// Finder reveal control: blue = external volume, gray = local machine.
    static func revealAccent(for path: String) -> Color {
        isExternalVolume(path) ? .blue : .secondary
    }
}

// MARK: - View insets
extension View {
    func contentMargin() -> some View {
        padding(.horizontal, Layout.margin)
    }

    func sectionInsets() -> some View {
        padding(.horizontal, Layout.margin)
            .padding(.vertical, Layout.spacingDefault)
    }

    func rowInsets() -> some View {
        padding(.horizontal, Layout.margin)
            .padding(.vertical, Layout.spacingTight + 1)
    }

    func toolbarInsets() -> some View {
        padding(.horizontal, Layout.margin)
            .padding(.vertical, Layout.spacingDefault)
    }

    func footerInsets() -> some View {
        padding(.horizontal, Layout.margin)
            .padding(.vertical, Layout.spacingDefault - 2)
    }
}

// MARK: - Tree guide (accordion child connectors)
enum TreeGuideMetrics {
    static let cardPad: CGFloat = 4
    static let rowPadH: CGFloat = Layout.margin
    static let chevronWidth: CGFloat = 10
    static let branchLength: CGFloat = 8
    static let lineWidth: CGFloat = 1.5

    /// Chevron-center column from the group card's leading edge.
    static var guideX: CGFloat { rowPadH + chevronWidth / 2 }
    /// Same column, measured inside the child list (after `.padding(.leading, cardPad)`).
    static var branchGuideX: CGFloat { guideX - cardPad }

    static let developerLineColor = Color.purple.opacity(0.22)
    static let defaultLineColor = Color.secondary.opacity(0.35)
}

/// Draws trunk segment + horizontal branch for hierarchical accordion lists.
struct TreeBranch: View {
    let guideOffset: CGFloat
    let branchLength: CGFloat
    let isFirst: Bool
    let isLast: Bool
    var lineColor: Color = TreeGuideMetrics.developerLineColor
    var lineWidth: CGFloat = TreeGuideMetrics.lineWidth

    var body: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2

            ZStack {
                if !isFirst {
                    Path { path in
                        path.move(to: CGPoint(x: guideOffset, y: 0))
                        path.addLine(to: CGPoint(x: guideOffset, y: midY))
                    }
                    .stroke(lineColor, lineWidth: lineWidth)
                }

                if !isLast {
                    Path { path in
                        path.move(to: CGPoint(x: guideOffset, y: midY))
                        path.addLine(to: CGPoint(x: guideOffset, y: geo.size.height))
                    }
                    .stroke(lineColor, lineWidth: lineWidth)
                }

                Path { path in
                    path.move(to: CGPoint(x: guideOffset, y: midY))
                    path.addLine(to: CGPoint(x: guideOffset + branchLength, y: midY))
                }
                .stroke(lineColor, lineWidth: lineWidth)
            }
        }
        .frame(width: guideOffset + branchLength)
    }
}

// MARK: - Shared list row pieces
struct ListRowDivider: View {
    var body: some View {
        Divider()
            .opacity(Layout.listDividerOpacity)
            .padding(.horizontal, Layout.margin)
            .padding(.vertical, Layout.listDividerPadding / 2)
    }
}

struct ListRowSizeLabel: View {
    let bytes: Int64
    var color: Color = .secondary
    var bold: Bool = false

    var body: some View {
        Text(formatBytes(bytes))
            .font(.system(size: bold ? 13 : 11, weight: bold ? .bold : .medium, design: .monospaced))
            .foregroundColor(color)
            .frame(width: bold ? nil : Layout.sizeColumnWidth, alignment: .trailing)
            .monospacedDigit()
    }
}

struct ListRowActions: View {
    let onTrash: () -> Void
    let onReveal: () -> Void
    var revealPath: String = ""
    var isCleaning: Bool = false
    var trashHelp: String = "Move to Trash"
    var revealHelp: String = "Show in Finder"

    var body: some View {
        HStack(spacing: Layout.spacingTight) {
            Button(action: onTrash) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .disabled(isCleaning)
            .help(trashHelp)

            Button(action: onReveal) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(PathDisplay.revealAccent(for: revealPath))
            .disabled(revealPath.isEmpty)
            .help(revealHelp)
        }
        .frame(width: Layout.actionsColumnWidth, alignment: .trailing)
    }
}

struct ListRowTrailing: View {
    let bytes: Int64
    var sizeColor: Color = .secondary
    var sizeBold: Bool = false
    let onTrash: () -> Void
    let onReveal: () -> Void
    var revealPath: String = ""
    var isCleaning: Bool = false
    var trashHelp: String = "Move to Trash"
    var revealHelp: String = "Show in Finder"

    var body: some View {
        HStack(spacing: Layout.spacingTight) {
            ListRowSizeLabel(bytes: bytes, color: sizeColor, bold: sizeBold)
            ListRowActions(
                onTrash: onTrash,
                onReveal: onReveal,
                revealPath: revealPath,
                isCleaning: isCleaning,
                trashHelp: trashHelp,
                revealHelp: revealHelp
            )
        }
    }
}

struct SubtleChip: View {
    let text: String
    var foreground: Color = .secondary
    var background: Color = Color.gray.opacity(0.1)

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(background)
            )
    }
}

struct AgeBadge: View {
    let days: Int
    var staleThreshold: Int = 30

    private var isStale: Bool { days > staleThreshold }

    var body: some View {
        SubtleChip(
            text: staleThreshold >= 60 ? "\(days)d ago" : "\(days)d",
            foreground: isStale ? .orange : .secondary,
            background: isStale ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1)
        )
    }
}

struct TagBadge: View {
    let text: String
    var tint: Color = .purple.opacity(0.6)

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
            )
    }
}

struct CountBadge: View {
    let count: String
    var tint: Color = .purple

    var body: some View {
        Text(count)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.6)))
    }
}

struct ChipButton: View {
    let icon: String
    let title: String
    var badge: Int = 0
    let tint: Color
    let action: () -> Void
    var help: String = ""

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0)
                        .background(tint.opacity(0.25))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .cornerRadius(5)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .foregroundColor(tint)
        .help(help)
    }
}
