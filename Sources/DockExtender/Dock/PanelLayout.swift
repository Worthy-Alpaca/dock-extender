import Foundation

/// Frames for one bar's window, the glass bar inside it and each tile.
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

    /// How much of the screen edge the bar covers.
    var length: CGFloat { edge == .bottom ? barFrame.width : barFrame.height }

    /// Gap between the Dock and a bar, and between one bar and the next.
    static var spacing: CGFloat { Metric.dockGap }

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
        /// Gap between the Dock and the bar, and between bars.
        static let dockGap: CGFloat = 8
        static let screenMargin: CGFloat = 6
        /// Transparent room around the bar so its shadow is not clipped.
        static let shadowMargin: CGFloat = 14
        /// Tiles are narrowed this far, and no further.
        static let minimumScale: CGFloat = 0.7
        /// Icon size the tile designs are drawn for.
        static let designTileSize: CGFloat = 57
    }

    // MARK: - One bar on its own

    /// Lays out a bar in whatever room there is, for when `share` finds no
    /// way to fit it whole. Tiles are narrowed as far as they go, and then as
    /// many are shown as fit; the first is shown even if it does not.
    ///
    /// `taken`: how far other bars already reach beyond the Dock's end on
    /// this side; the bar is placed past them.
    static func make(dock: DockGeometry, side: Settings.Side, widthFactors: [CGFloat], taken: CGFloat = 0) -> PanelLayout {
        let sizes = Sizes(dock)
        let lengths = widthFactors.map { sizes.length(ofTileWithFactor: $0) }
        let available = Room(dock: dock, side: side, taken: taken).available

        func fittingScale(_ count: Int) -> CGFloat {
            let total = lengths.prefix(count).reduce(0, +)
            return total > 0 ? (available - sizes.chrome(tiles: count)) / total : 1
        }
        var count = lengths.count
        while count > 1, fittingScale(count) < Metric.minimumScale {
            count -= 1
        }
        let scale = min(1, max(Metric.minimumScale, fittingScale(count)))
        return build(dock: dock, side: side, lengths: lengths.prefix(count).map { $0 * scale }, scale: scale, taken: taken)
    }

    // MARK: - Bars sharing one end of the Dock

    /// What one bar gets when several divide the room at one end of the Dock.
    struct Share: Equatable {
        /// Length of each of its tiles along the Dock's edge.
        var lengths: [CGFloat]
        /// How much its tiles were narrowed, 1 being not at all.
        var scale: CGFloat
    }

    /// Divides the room at one end of the Dock among the bars set to be
    /// there; `bars` holds each bar's tile width factors. Nil when they
    /// cannot all be there, however small.
    ///
    /// Room is found in two steps. Tiles wider than a Dock icon first give up
    /// their extra width, down to one icon's width. If that is not enough,
    /// every tile is narrowed by the same amount, as far as `minimumScale`.
    ///
    /// `taken`: how far bars placed earlier already reach at this end.
    static func share(dock: DockGeometry, side: Settings.Side, among bars: [[CGFloat]], taken: CGFloat = 0) -> [Share]? {
        let sizes = Sizes(dock)
        let fixed = bars.map { sizes.chrome(tiles: $0.count) }.reduce(0, +)
            + Metric.dockGap * CGFloat(max(bars.count - 1, 0))
        let room = Room(dock: dock, side: side, taken: taken).available - fixed

        let wanted = bars.map { $0.map { sizes.length(ofTileWithFactor: $0) } }
        let least = bars.map { $0.map { sizes.length(ofTileWithFactor: min($0, 1)) } }
        let wantedTotal = wanted.joined().reduce(0, +)
        let leastTotal = least.joined().reduce(0, +)

        if wantedTotal <= room {
            return wanted.map { Share(lengths: $0, scale: 1) }
        }
        // Shortened lengths land on half points, rounding down, so that tiles
        // stay on whole pixels and never add up to more than the room.
        func snapped(_ length: CGFloat) -> CGFloat {
            (length * 2).rounded(.down) / 2
        }
        if leastTotal <= room {
            // Each wide tile gives up the same share of its extra width.
            let given = (wantedTotal - room) / (wantedTotal - leastTotal)
            return zip(wanted, least).map { wanted, least in
                Share(lengths: zip(wanted, least).map { snapped($0 - ($0 - $1) * given) }, scale: 1)
            }
        }
        guard leastTotal > 0 else { return nil }
        let scale = room / leastTotal
        guard scale >= Metric.minimumScale else { return nil }
        return least.map { Share(lengths: $0.map { snapped($0 * scale) }, scale: scale) }
    }

    /// Lays out a bar with the tile lengths `share(dock:side:among:)` gave it.
    static func make(dock: DockGeometry, side: Settings.Side, share: Share, taken: CGFloat) -> PanelLayout {
        build(dock: dock, side: side, lengths: share.lengths, scale: share.scale, taken: taken)
    }

    // MARK: - Building blocks

    /// Sizes that follow from how deep the Dock is.
    private struct Sizes {
        var barThickness: CGFloat
        /// Space between the bar's edge and the tiles.
        var padding: CGFloat
        /// A tile's size across the bar; along it, a square tile is as long.
        var tile: CGFloat
        var horizontal: Bool

        init(_ dock: DockGeometry) {
            // The bar is exactly as thick as the Dock's own, which fills its
            // strip but for the margins. Everything inside follows from that.
            // Padding lands on half points so the tiles stay on whole pixels.
            barThickness = max(Metric.minimumBar, dock.thickness - 2 * Metric.margin)
            padding = (barThickness * Metric.paddingShare * 2).rounded() / 2
            tile = barThickness - 2 * padding
            horizontal = dock.edge == .bottom
        }

        /// Tiles are always square in a vertical Dock.
        func length(ofTileWithFactor factor: CGFloat) -> CGFloat {
            horizontal ? tile * factor : tile
        }

        /// What a bar with `tiles` tiles is longer than its tiles: the padding
        /// at both ends and the gaps between tiles.
        func chrome(tiles: Int) -> CGFloat {
            2 * padding + Metric.tileSpacing * CGFloat(max(tiles - 1, 0))
        }
    }

    /// The stretch of screen edge at one end of the Dock.
    private struct Room {
        /// The screen edge the Dock is on, end to end.
        var axis: ClosedRange<CGFloat>
        /// Whether bars at this end sit at higher coordinates than the Dock.
        var towardHigh: Bool
        /// The Dock together with the bars already placed at this end: to a
        /// new bar they are one obstacle. Nil when the Dock's position is
        /// unknown.
        var obstacle: ClosedRange<CGFloat>?
        /// How long a bar placed here can be.
        var available: CGFloat
        var taken: CGFloat

        init(dock: DockGeometry, side: Settings.Side, taken: CGFloat) {
            let horizontal = dock.edge == .bottom
            axis = horizontal
                ? dock.usableFrame.minX...dock.usableFrame.maxX
                : dock.usableFrame.minY...dock.usableFrame.maxY
            // In a vertical Dock "trailing" (the Trash end) is the bottom.
            let trailingIsHigh = horizontal
            towardHigh = (side == .trailing) == trailingIsHigh
            self.taken = taken

            let towardHigh = towardHigh
            obstacle = dock.span.map { span in
                towardHigh ? span.lowerBound...(span.upperBound + taken) : (span.lowerBound - taken)...span.upperBound
            }
            if let obstacle {
                let room = towardHigh ? axis.upperBound - obstacle.upperBound : obstacle.lowerBound - axis.lowerBound
                available = room - Metric.dockGap - Metric.screenMargin
            } else {
                available = axis.upperBound - axis.lowerBound - 2 * Metric.screenMargin - taken
            }
        }

        /// Where a bar `length` long starts: against the obstacle, or in the
        /// corner when the Dock's position is unknown. Always on screen.
        func start(ofBarWithLength length: CGFloat) -> CGFloat {
            let start: CGFloat
            if let obstacle {
                start = towardHigh ? obstacle.upperBound + Metric.dockGap : obstacle.lowerBound - Metric.dockGap - length
            } else {
                start = towardHigh
                    ? axis.upperBound - Metric.screenMargin - taken - length
                    : axis.lowerBound + Metric.screenMargin + taken
            }
            let lowest = axis.lowerBound + Metric.screenMargin
            let highest = max(lowest, axis.upperBound - Metric.screenMargin - length)
            return min(max(start, lowest), highest)
        }
    }

    /// Frames for a bar whose tiles are `lengths` long.
    private static func build(
        dock: DockGeometry,
        side: Settings.Side,
        lengths: [CGFloat],
        scale: CGFloat,
        taken: CGFloat
    ) -> PanelLayout {
        let sizes = Sizes(dock)
        let barThickness = sizes.barThickness
        let barLength = sizes.chrome(tiles: lengths.count) + lengths.reduce(0, +)
        let start = Room(dock: dock, side: side, taken: taken).start(ofBarWithLength: barLength)

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
        var offset = sizes.padding
        for length in lengths {
            if sizes.horizontal {
                tileFrames.append(CGRect(x: offset, y: sizes.padding, width: length, height: sizes.tile))
            } else {
                tileFrames.append(CGRect(x: sizes.padding, y: barLength - offset - length, width: sizes.tile, height: length))
            }
            offset += length + Metric.tileSpacing
        }

        return PanelLayout(
            shownFrame: shownFrame,
            hiddenFrame: hiddenFrame,
            barFrame: barFrame,
            tileFrames: tileFrames,
            // Concentric with the tiles' own rounded corners.
            cornerRadius: sizes.tile * 0.23 + sizes.padding,
            contentScale: sizes.tile / Metric.designTileSize * scale,
            edge: dock.edge
        )
    }
}
