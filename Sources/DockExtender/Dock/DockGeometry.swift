import AppKit

enum DockEdge: Sendable {
    case bottom, left, right
}

/// Where the Dock is and how big it is, in AppKit screen coordinates
/// (origin at the bottom-left of the primary display).
struct DockGeometry: Equatable {
    var edge: DockEdge
    var autohide: Bool
    /// Dock icon size in points.
    var tileSize: CGFloat
    /// Frame of the screen showing the Dock.
    var screenFrame: CGRect
    /// The part of that screen not covered by the menu bar.
    var usableFrame: CGRect
    /// Extent of the Dock bar along its screen edge: an x-range for a bottom
    /// Dock, a y-range for a side Dock. Nil when the bar's position is unknown.
    var span: ClosedRange<CGFloat>?
    /// Depth of the strip the Dock occupies, measured in from the screen edge.
    var thickness: CGFloat

    /// How far `point` is from the Dock's screen edge; infinite on other screens.
    func depth(of point: CGPoint) -> CGFloat {
        guard screenFrame.insetBy(dx: -1, dy: -1).contains(point) else { return .infinity }
        switch edge {
        case .bottom: return point.y - screenFrame.minY
        case .left: return point.x - screenFrame.minX
        case .right: return screenFrame.maxX - point.x
        }
    }

    /// Strip depth for an icon size when it cannot be measured (a hidden Dock
    /// reserves no screen space): icon + padding inside the bar + the gaps
    /// around it.
    static func estimatedThickness(tileSize: CGFloat) -> CGFloat {
        tileSize + 22
    }

    @MainActor
    static func current() -> DockGeometry? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }

        let edge = CoreDock.edge ?? DockPreferences.edge ?? .bottom
        let autohide = CoreDock.autohide ?? (DockPreferences.value("autohide") as? Bool) ?? false
        let tileSize = CoreDock.tileSize
            ?? (DockPreferences.value("tilesize") as? NSNumber).map { CGFloat($0.doubleValue) }
            ?? 48

        // CoreDock uses top-left-origin display coordinates; flip to AppKit's.
        let bar = CoreDock.rect.map {
            CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
        }

        let screen = bar.flatMap { screenHosting($0, edge: edge, among: screens) } ?? NSScreen.main ?? primary
        let frame = screen.frame
        var thickness = estimatedThickness(tileSize: tileSize)
        var usable = frame

        // visibleFrame is a round trip to the window server, so only ask when
        // the answer matters: a Dock that is always showing reserves its strip
        // there, and a vertical Dock shares its edge with the menu bar.
        if !autohide || edge != .bottom {
            let visible = screen.visibleFrame
            let reserved: CGFloat
            switch edge {
            case .bottom: reserved = visible.minY - frame.minY
            case .left: reserved = visible.minX - frame.minX
            case .right: reserved = frame.maxX - visible.maxX
            }
            if !autohide, reserved > 8 {
                thickness = reserved
            }
            usable.size.height = visible.maxY - frame.minY
        }

        let span: ClosedRange<CGFloat>? = bar.map {
            edge == .bottom ? $0.minX...$0.maxX : $0.minY...$0.maxY
        }

        return DockGeometry(
            edge: edge,
            autohide: autohide,
            tileSize: tileSize,
            screenFrame: frame,
            usableFrame: usable,
            span: span,
            thickness: thickness
        )
    }

    /// The screen whose Dock edge the bar sits on.
    @MainActor
    private static func screenHosting(_ bar: CGRect, edge: DockEdge, among screens: [NSScreen]) -> NSScreen? {
        func distance(_ screen: NSScreen) -> CGFloat? {
            let frame = screen.frame
            switch edge {
            case .bottom:
                guard (frame.minX...frame.maxX).contains(bar.midX) else { return nil }
                return abs(bar.minY - frame.minY)
            case .left:
                guard (frame.minY...frame.maxY).contains(bar.midY) else { return nil }
                return abs(bar.minX - frame.minX)
            case .right:
                guard (frame.minY...frame.maxY).contains(bar.midY) else { return nil }
                return abs(bar.maxX - frame.maxX)
            }
        }
        return screens
            .compactMap { screen in distance(screen).map { (screen, $0) } }
            .min { $0.1 < $1.1 }?
            .0
    }
}
