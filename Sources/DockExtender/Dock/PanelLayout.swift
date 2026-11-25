import Foundation

/// Frames for the panel window, the glass bar inside it and each tile.
/// Pure geometry: derived entirely from the Dock's position and size and the
/// widget list.
struct PanelLayout: Equatable {
    /// Window frame when the panel is showing (screen coordinates).
    var shownFrame: CGRect
    /// Window frame once slid past the screen edge.
    var hiddenFrame: CGRect
    /// The glass bar, in window coordinates.
    var barFrame: CGRect
    /// One frame per visible tile, in bar coordinates. May hold fewer entries
    /// than there are widgets when the screen has no room for all of them.
    var tileFrames: [CGRect]
    var cornerRadius: CGFloat
    /// Value handed to tiles as `tileScale`.
    var contentScale: CGFloat
    var edge: DockEdge

    private enum Metric {
        /// Margin the Dock's bar keeps inside its strip: the gap to the screen
        /// edge, and the same again on the side facing the desktop.
        static let margin: CGFloat = 5
        /// Share of the bar's thickness left free on each side of the tiles.
        /// The Dock pads bigger icons more, so this is a share, not a fixed
        /// size: the bar looks the same at every Dock size, only scaled.
        static let paddingShare: CGFloat = 0.115
        /// Thinnest bar that still holds something readable.
        static let minimumBar: CGFloat = 30
        /// Gap between tiles, the same as between the Dock's icons.
        static let tileSpacing: CGFloat = 4
        /// Gap between the Dock and the bar.
        static let dockGap: CGFloat = 8
        static let screenMargin: CGFloat = 6
        /// Transparent room around the bar so its shadow is not clipped.
        static let shadowMargin: CGFloat = 14
        /// Tiles shrink this far before any get dropped.
        static let minimumScale: CGFloat = 0.7
        /// Icon size the tile designs are drawn for.
        static let designTileSize: CGFloat = 57
    }

    static func make(dock: DockGeometry, side: Settings.Side, widthFactors: [CGFloat]) -> PanelLayout {
        let horizontal = dock.edge == .bottom
        // The bar is exactly as thick as the Dock's own, which fills its strip
        // but for the margins. Everything inside follows from that. Padding
        // lands on half points so the tiles stay on whole pixels.
        let barThickness = max(Metric.minimumBar, dock.thickness - 2 * Metric.margin)
        let padding = (barThickness * Metric.paddingShare * 2).rounded() / 2
        let tile = barThickness - 2 * padding
        let lengths = widthFactors.map { horizontal ? tile * $0 : tile }

        // Room along the Dock's edge on the chosen side. In a vertical Dock
        // "trailing" (the Trash end) is the bottom.
        let axis = horizontal
            ? dock.usableFrame.minX...dock.usableFrame.maxX
            : dock.usableFrame.minY...dock.usableFrame.maxY
        let trailingIsHigh = horizontal
        let towardHigh = (side == .trailing) == trailingIsHigh

        let available: CGFloat
        if let span = dock.span {
            let room = towardHigh ? axis.upperBound - span.upperBound : span.lowerBound - axis.lowerBound
            available = room - Metric.dockGap - Metric.screenMargin
        } else {
            available = axis.upperBound - axis.lowerBound - 2 * Metric.screenMargin
        }

        // Shrink tiles to fit; if that is not enough, show as many as fit.
        func chrome(_ count: Int) -> CGFloat {
            2 * padding + Metric.tileSpacing * CGFloat(max(count - 1, 0))
        }
        func fittingScale(_ count: Int) -> CGFloat {
            let total = lengths.prefix(count).reduce(0, +)
            return total > 0 ? (available - chrome(count)) / total : 1
        }
        var count = lengths.count
        while count > 1, fittingScale(count) < Metric.minimumScale {
            count -= 1
        }
        let scale = min(1, max(Metric.minimumScale, fittingScale(count)))
        let shown = lengths.prefix(count).map { $0 * scale }
        let barLength = chrome(count) + shown.reduce(0, +)

        // Position along the edge: against the Dock, or in the corner when the
        // Dock's position is unknown. Always kept on screen.
        var start: CGFloat
        if let span = dock.span {
            start = towardHigh ? span.upperBound + Metric.dockGap : span.lowerBound - Metric.dockGap - barLength
        } else {
            start = towardHigh ? axis.upperBound : axis.lowerBound
        }
        let lowest = axis.lowerBound + Metric.screenMargin
        let highest = max(lowest, axis.upperBound - Metric.screenMargin - barLength)
        start = min(max(start, lowest), highest)

        let shadow = Metric.shadowMargin
        let depth = Metric.margin + barThickness + shadow
        let screen = dock.screenFrame
        var shownFrame: CGRect
        var barFrame: CGRect
        var hiddenFrame: CGRect

        switch dock.edge {
        case .bottom:
            shownFrame = CGRect(x: start - shadow, y: screen.minY, width: barLength + 2 * shadow, height: depth)
            barFrame = CGRect(x: shadow, y: Metric.margin, width: barLength, height: barThickness)
            hiddenFrame = shownFrame.offsetBy(dx: 0, dy: -depth)
        case .left:
            shownFrame = CGRect(x: screen.minX, y: start - shadow, width: depth, height: barLength + 2 * shadow)
            barFrame = CGRect(x: Metric.margin, y: shadow, width: barThickness, height: barLength)
            hiddenFrame = shownFrame.offsetBy(dx: -depth, dy: 0)
        case .right:
            shownFrame = CGRect(x: screen.maxX - depth, y: start - shadow, width: depth, height: barLength + 2 * shadow)
            barFrame = CGRect(x: shadow, y: shadow, width: barThickness, height: barLength)
            hiddenFrame = shownFrame.offsetBy(dx: depth, dy: 0)
        }

        // Tiles run left to right in a bottom Dock, top to bottom in a side Dock.
        var tileFrames: [CGRect] = []
        var offset = padding
        for length in shown {
            if horizontal {
                tileFrames.append(CGRect(x: offset, y: padding, width: length, height: tile))
            } else {
                tileFrames.append(CGRect(x: padding, y: barLength - offset - length, width: tile, height: length))
            }
            offset += length + Metric.tileSpacing
        }

        return PanelLayout(
            shownFrame: shownFrame,
            hiddenFrame: hiddenFrame,
            barFrame: barFrame,
            tileFrames: tileFrames,
            // Concentric with the tiles' own rounded corners.
            cornerRadius: tile * 0.23 + padding,
            contentScale: tile / Metric.designTileSize * scale,
            edge: dock.edge
        )
    }
}
