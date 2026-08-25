import AppKit
import CoreGraphics
import DiskScannerCore
import SwiftUI

struct DiskSpaceTreemapView: View {
    let nodes: [DiskFileNode]
    let selectedNodeID: String?
    let onSelect: (String?) -> Void
    let onOpen: (String) -> Void

    @State private var hoveredTileID: String?
    @State private var pointerLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let chartBounds = CGRect(
                x: 14,
                y: 14,
                width: max(geometry.size.width - 28, 0),
                height: max(geometry.size.height - 28, 0)
            )
            let tiles = DiskSpaceTreemapLayout.tiles(
                for: nodes,
                in: chartBounds,
                minimumTileArea: 130
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for tile in tiles {
                        draw(
                            tile,
                            context: &context,
                            isSelected: tile.nodeID == selectedNodeID,
                            isHovered: tile.id == hoveredTileID
                        )
                    }
                }
                .allowsHitTesting(false)

                DiskSpacePointerLayer(
                    onHover: { point in
                        pointerLocation = point
                        hoveredTileID = point.flatMap { tile(at: $0, in: tiles)?.id }
                    },
                    onClick: { point, clickCount in
                        guard let tile = tile(at: point, in: tiles) else {
                            onSelect(nil)
                            return
                        }
                        guard let nodeID = tile.nodeID else { return }
                        if clickCount >= 2, tile.isDirectory {
                            onOpen(nodeID)
                        } else {
                            onSelect(nodeID)
                        }
                    }
                )

                if let hoveredTile = tiles.first(where: { $0.id == hoveredTileID }),
                   let pointerLocation {
                    DiskSpaceTreemapTooltip(tile: hoveredTile)
                        .fixedSize()
                        .position(
                            tooltipPosition(
                                pointer: pointerLocation,
                                tooltipSize: CGSize(width: 220, height: 62),
                                containerSize: geometry.size
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.36))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage treemap")
            .accessibilityHint("Click an item to select it. Double-click a folder to open it.")
        }
    }

    private func tile(
        at point: CGPoint,
        in tiles: [DiskSpaceTreemapTile]
    ) -> DiskSpaceTreemapTile? {
        tiles.first { $0.rect.contains(point) }
    }

    private func draw(
        _ tile: DiskSpaceTreemapTile,
        context: inout GraphicsContext,
        isSelected: Bool,
        isHovered: Bool
    ) {
        let rect = tile.rect.insetBy(dx: 1.5, dy: 1.5)
        guard rect.width > 0, rect.height > 0 else { return }

        let radius = min(7, min(rect.width, rect.height) * 0.12)
        let path = Path(roundedRect: rect, cornerRadius: radius)
        let baseColor = tile.isAggregate
            ? Color.secondary.opacity(0.30)
            : Self.palette[tile.colorIndex % Self.palette.count]

        context.fill(path, with: .color(baseColor.opacity(isHovered ? 0.96 : 0.82)))
        context.stroke(
            path,
            with: .color(Color.white.opacity(0.34)),
            lineWidth: 0.7
        )

        if isSelected {
            let selectionPath = Path(
                roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                cornerRadius: max(radius - 1.5, 0)
            )
            context.stroke(selectionPath, with: .color(.accentColor), lineWidth: 3)
        } else if isHovered {
            context.stroke(
                path,
                with: .color(Color.primary.opacity(0.72)),
                lineWidth: 1.6
            )
        }

        guard rect.width >= 74, rect.height >= 38 else { return }

        let label = Text(tile.label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
        context.draw(
            label,
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 8),
            anchor: .topLeading
        )

        if rect.width >= 96, rect.height >= 58 {
            let size = Text(formatBytes(tile.allocatedBytes))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.78))
            context.draw(
                size,
                at: CGPoint(x: rect.minX + 8, y: rect.minY + 27),
                anchor: .topLeading
            )
        }
    }

    private func tooltipPosition(
        pointer: CGPoint,
        tooltipSize: CGSize,
        containerSize: CGSize
    ) -> CGPoint {
        let halfWidth = tooltipSize.width / 2
        let halfHeight = tooltipSize.height / 2
        let preferredX = pointer.x + halfWidth + 14
        let preferredY = pointer.y + halfHeight + 14
        return CGPoint(
            x: min(max(preferredX, halfWidth + 8), containerSize.width - halfWidth - 8),
            y: min(max(preferredY, halfHeight + 8), containerSize.height - halfHeight - 8)
        )
    }

    private static let palette: [Color] = [
        Color(red: 0.18, green: 0.49, blue: 0.93),
        Color(red: 0.13, green: 0.68, blue: 0.58),
        Color(red: 0.55, green: 0.39, blue: 0.90),
        Color(red: 0.95, green: 0.55, blue: 0.16),
        Color(red: 0.89, green: 0.30, blue: 0.39),
        Color(red: 0.20, green: 0.63, blue: 0.83),
        Color(red: 0.50, green: 0.67, blue: 0.20),
        Color(red: 0.84, green: 0.38, blue: 0.72)
    ]
}

private struct DiskSpaceTreemapTooltip: View {
    let tile: DiskSpaceTreemapTile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(formatBytes(tile.allocatedBytes))
                    .monospacedDigit()
                if let groupedItemCount = tile.groupedItemCount {
                    Text("· \(groupedItemCount.formatted()) items")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: 196, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }
}

private struct DiskSpacePointerLayer: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.onHover = onHover
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: PointerView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
    }

    final class PointerView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        private var trackingAreaReference: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaReference {
                removeTrackingArea(trackingAreaReference)
            }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            trackingAreaReference = trackingArea
        }

        override func mouseMoved(with event: NSEvent) {
            onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
        }

        override func mouseDown(with event: NSEvent) {
            onClick(convert(event.locationInWindow, from: nil), event.clickCount)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

private struct DiskSpaceTreemapTile: Identifiable {
    let id: String
    let nodeID: String?
    let label: String
    let allocatedBytes: Int64
    let groupedItemCount: Int?
    let isDirectory: Bool
    let isAggregate: Bool
    let colorIndex: Int
    let rect: CGRect
}

private enum DiskSpaceTreemapLayout {
    private struct Entry {
        let id: String
        let nodeID: String?
        let label: String
        let allocatedBytes: Int64
        let groupedItemCount: Int?
        let isDirectory: Bool
        let isAggregate: Bool
        let colorIndex: Int
    }

    private struct WeightedEntry {
        let entry: Entry
        let area: CGFloat
    }

    private struct PositionedEntry {
        let entry: Entry
        let rect: CGRect
    }

    static func tiles(
        for nodes: [DiskFileNode],
        in bounds: CGRect,
        minimumTileArea: CGFloat
    ) -> [DiskSpaceTreemapTile] {
        guard bounds.width > 0, bounds.height > 0, !nodes.isEmpty else { return [] }

        let sortedNodes = nodes
            .filter { $0.allocatedBytes > 0 }
            .sorted { lhs, rhs in
                if lhs.allocatedBytes == rhs.allocatedBytes {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.allocatedBytes > rhs.allocatedBytes
            }

        let totalBytes = sortedNodes.reduce(0.0) {
            $0 + Double(max($1.allocatedBytes, 1))
        }
        let availableArea = max(bounds.width * bounds.height, 1)
        var visibleEntries: [Entry] = []
        var groupedBytes: Int64 = 0
        var groupedCount = 0

        for (index, node) in sortedNodes.enumerated() {
            let projectedArea = availableArea
                * CGFloat(Double(max(node.allocatedBytes, 1)) / max(totalBytes, 1))
            if projectedArea < minimumTileArea {
                groupedCount += 1
                groupedBytes = addingClamped(groupedBytes, node.allocatedBytes)
            } else {
                visibleEntries.append(
                    Entry(
                        id: node.id,
                        nodeID: node.id,
                        label: node.name,
                        allocatedBytes: node.allocatedBytes,
                        groupedItemCount: nil,
                        isDirectory: node.isDirectory,
                        isAggregate: false,
                        colorIndex: index
                    )
                )
            }
        }

        if groupedCount == 1,
           let groupedNode = sortedNodes.last(where: { node in
               !visibleEntries.contains(where: { $0.nodeID == node.id })
           }) {
            visibleEntries.append(
                Entry(
                    id: groupedNode.id,
                    nodeID: groupedNode.id,
                    label: groupedNode.name,
                    allocatedBytes: groupedNode.allocatedBytes,
                    groupedItemCount: nil,
                    isDirectory: groupedNode.isDirectory,
                    isAggregate: false,
                    colorIndex: visibleEntries.count
                )
            )
        } else if groupedCount > 1 {
            visibleEntries.append(
                Entry(
                    id: "cleardisk-smaller-items",
                    nodeID: nil,
                    label: "Smaller Items",
                    allocatedBytes: groupedBytes,
                    groupedItemCount: groupedCount,
                    isDirectory: false,
                    isAggregate: true,
                    colorIndex: visibleEntries.count
                )
            )
        }

        return squarifiedEntries(visibleEntries, in: bounds).map { positioned in
            DiskSpaceTreemapTile(
                id: positioned.entry.id,
                nodeID: positioned.entry.nodeID,
                label: positioned.entry.label,
                allocatedBytes: positioned.entry.allocatedBytes,
                groupedItemCount: positioned.entry.groupedItemCount,
                isDirectory: positioned.entry.isDirectory,
                isAggregate: positioned.entry.isAggregate,
                colorIndex: positioned.entry.colorIndex,
                rect: positioned.rect
            )
        }
    }

    private static func squarifiedEntries(
        _ entries: [Entry],
        in bounds: CGRect
    ) -> [PositionedEntry] {
        guard !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let totalWeight = entries.reduce(0.0) {
            $0 + Double(max($1.allocatedBytes, 1))
        }
        let scale = Double(bounds.width * bounds.height) / max(totalWeight, 1)
        let weightedEntries = entries.map {
            WeightedEntry(
                entry: $0,
                area: CGFloat(Double(max($0.allocatedBytes, 1)) * scale)
            )
        }

        var nextEntryIndex = 0
        var remainingBounds = bounds
        var row: [WeightedEntry] = []
        var rowArea = CGFloat(0)
        var rowMinimumArea = CGFloat.greatestFiniteMagnitude
        var rowMaximumArea = CGFloat(0)
        var result: [PositionedEntry] = []

        while nextEntryIndex < weightedEntries.count {
            let next = weightedEntries[nextEntryIndex]
            let shortSide = min(remainingBounds.width, remainingBounds.height)
            let candidateArea = rowArea + next.area
            let candidateMinimumArea = min(rowMinimumArea, next.area)
            let candidateMaximumArea = max(rowMaximumArea, next.area)

            if row.isEmpty || worstAspectRatio(
                sum: candidateArea,
                minimum: candidateMinimumArea,
                maximum: candidateMaximumArea,
                shortSide: shortSide
            ) <= worstAspectRatio(
                sum: rowArea,
                minimum: rowMinimumArea,
                maximum: rowMaximumArea,
                shortSide: shortSide
            ) {
                row.append(next)
                rowArea = candidateArea
                rowMinimumArea = candidateMinimumArea
                rowMaximumArea = candidateMaximumArea
                nextEntryIndex += 1
            } else {
                remainingBounds = layoutRow(
                    row,
                    area: rowArea,
                    in: remainingBounds,
                    into: &result
                )
                row.removeAll(keepingCapacity: true)
                rowArea = 0
                rowMinimumArea = .greatestFiniteMagnitude
                rowMaximumArea = 0
            }
        }

        if !row.isEmpty {
            _ = layoutRow(row, area: rowArea, in: remainingBounds, into: &result)
        }
        return result
    }

    private static func worstAspectRatio(
        sum: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        shortSide: CGFloat
    ) -> CGFloat {
        guard shortSide > 0, sum > 0, minimum > 0 else { return .infinity }
        let sumSquared = sum * sum
        let sideSquared = shortSide * shortSide
        return max(
            (sideSquared * maximum) / sumSquared,
            sumSquared / (sideSquared * minimum)
        )
    }

    @discardableResult
    private static func layoutRow(
        _ row: [WeightedEntry],
        area rowArea: CGFloat,
        in bounds: CGRect,
        into result: inout [PositionedEntry]
    ) -> CGRect {
        guard !row.isEmpty, bounds.width > 0, bounds.height > 0 else { return bounds }

        if bounds.width >= bounds.height {
            let columnWidth = min(rowArea / bounds.height, bounds.width)
            var cursorY = bounds.minY
            for (index, weightedEntry) in row.enumerated() {
                let height = index == row.count - 1
                    ? max(bounds.maxY - cursorY, 0)
                    : min(
                        weightedEntry.area / max(columnWidth, .leastNonzeroMagnitude),
                        bounds.maxY - cursorY
                    )
                result.append(
                    PositionedEntry(
                        entry: weightedEntry.entry,
                        rect: CGRect(
                            x: bounds.minX,
                            y: cursorY,
                            width: columnWidth,
                            height: height
                        )
                    )
                )
                cursorY += height
            }
            return CGRect(
                x: bounds.minX + columnWidth,
                y: bounds.minY,
                width: max(bounds.width - columnWidth, 0),
                height: bounds.height
            )
        }

        let rowHeight = min(rowArea / bounds.width, bounds.height)
        var cursorX = bounds.minX
        for (index, weightedEntry) in row.enumerated() {
            let width = index == row.count - 1
                ? max(bounds.maxX - cursorX, 0)
                : min(
                    weightedEntry.area / max(rowHeight, .leastNonzeroMagnitude),
                    bounds.maxX - cursorX
                )
            result.append(
                PositionedEntry(
                    entry: weightedEntry.entry,
                    rect: CGRect(
                        x: cursorX,
                        y: bounds.minY,
                        width: width,
                        height: rowHeight
                    )
                )
            )
            cursorX += width
        }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + rowHeight,
            width: bounds.width,
            height: max(bounds.height - rowHeight, 0)
        )
    }

    private static func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
