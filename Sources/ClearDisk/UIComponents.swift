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
    static let sectionVertical: CGFloat = 10
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

// MARK: - Shared list row pieces
struct ListRowSizeLabel: View {
    let bytes: Int64
    var color: Color = .secondary
    var bold: Bool = false

    var body: some View {
        Text(formatBytes(bytes))
            .font(.system(size: bold ? 13 : 11, weight: bold ? .bold : .medium, design: .monospaced))
            .foregroundColor(color)
            .frame(width: bold ? nil : 65, alignment: .trailing)
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
            .foregroundColor(.blue)
            .disabled(revealPath.isEmpty)
            .help(revealHelp)
        }
    }
}

struct AgeBadge: View {
    let days: Int
    var staleThreshold: Int = 30

    private var isStale: Bool { days > staleThreshold }

    var body: some View {
        Text(staleThreshold >= 60 ? "\(days)d ago" : "\(days)d")
            .font(.system(size: 9))
            .foregroundColor(isStale ? .orange : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isStale ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
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
        }
        .buttonStyle(.plain)
        .foregroundColor(tint)
        .help(help)
    }
}

struct DefaultFolderChip: View {
    let label: String
    let path: String

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundColor(.primary.opacity(0.85))
            .padding(.horizontal, Layout.spacingDefault)
            .padding(.vertical, Layout.spacingTight)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(6)
            .help(PathDisplay.tilde(path))
    }
}

// MARK: - Wrapping flow layout
struct WrappingFlowLayout: SwiftUI.Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + verticalSpacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
            totalWidth = max(totalWidth, x - horizontalSpacing)
            totalHeight = y + rowHeight
        }

        return CGSize(
            width: proposal.width ?? totalWidth,
            height: totalHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
