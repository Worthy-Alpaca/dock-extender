import AppKit

/// Measures how deep the Dock really is.
///
/// The icon size in the Dock's settings does not say how tall the Dock ends
/// up: the padding it adds grows with the icon size, and when the icons would
/// not fit the screen it draws them smaller than asked. For an auto-hiding
/// Dock nothing reports the result (no screen space is reserved for it, and
/// CoreDock's rect is collapsed onto the screen edge).
///
/// What can be asked, without any permission, is which window a click at a
/// given point would land in. The Dock claims clicks in a plain rectangle
/// reaching in from its screen edge, so walking inward until the answer stops
/// being the Dock finds how deep it is.
///
/// This only works while the Dock is on screen, and the rectangle slides in
/// and out with the Dock, so a reading taken while the Dock is moving comes
/// out short. Callers wait for two readings that agree.
@MainActor
enum DockProbe {
    /// Readings are taken on the pixel grid of a Retina display.
    private static let grid: CGFloat = 0.5
    /// Deeper than any Dock gets.
    private static let limit: CGFloat = 280
    /// Shallower than any Dock gets; less than this is a Dock still sliding in.
    private static let minimum: CGFloat = 24
    /// Coarse step of the search, in grid rows.
    private static let stride = 12

    /// Depth of the Dock's strip in points, or nil when the Dock is not where
    /// `dock` says it is (hidden, mid-slide or covered).
    ///
    /// `windows` holds the window numbers the Dock draws its bar in.
    static func reach(of dock: DockGeometry, windows: Set<Int>) -> CGFloat? {
        guard let span = dock.span, !windows.isEmpty else { return nil }
        let length = span.upperBound - span.lowerBound

        // Three lines across the Dock, and the middle answer of the three, so
        // that something covering part of the Dock does not decide the result.
        let readings = [0.5, 0.25, 0.75]
            .compactMap { reach(of: dock, windows: windows, along: span.lowerBound + length * $0) }
            .sorted()
        guard !readings.isEmpty else { return nil }
        return readings[readings.count / 2]
    }

    private static func reach(of dock: DockGeometry, windows: Set<Int>, along position: CGFloat) -> CGFloat? {
        // Row n is the line of pixels n grid steps in from the screen edge.
        func isDock(_ row: Int) -> Bool {
            let point = dock.point(along: position, depth: (CGFloat(row) + 0.5) * grid)
            return windows.contains(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
        }

        // Nearly always nothing has changed, which two tests confirm.
        let expected = Int((dock.thickness / grid).rounded())
        if expected > 0, isDock(expected - 1), !isDock(expected) {
            return CGFloat(expected) * grid
        }

        // Otherwise come in from beyond the Dock in coarse steps until one
        // lands on it, then narrow down to the exact row where it ends.
        var outside = Int(limit / grid)
        guard !isDock(outside) else { return nil }
        var inside = outside - stride
        while inside >= 0, !isDock(inside) {
            outside = inside
            inside -= stride
        }
        guard inside >= 0 else { return nil }
        while outside - inside > 1 {
            let middle = (inside + outside) / 2
            if isDock(middle) {
                inside = middle
            } else {
                outside = middle
            }
        }
        let depth = CGFloat(outside) * grid
        return depth >= minimum ? depth : nil
    }
}

/// Depths the Dock has been measured at, by icon size, kept between launches
/// so the bar starts at the right height instead of at an estimate.
struct DockCalibration: Equatable {
    /// Measured depth for each edge and icon-size setting.
    private var depths: [DockEdge: [Int: CGFloat]] = [:]

    /// What the Dock adds around its icons, in total, for a measurement to be
    /// believed about other sizes. A full Dock shrinks its icons to fit and so
    /// measures far less than its setting suggests; that is true for the size
    /// it was measured at and says nothing about the next size along.
    private static let plausiblePadding: ClosedRange<CGFloat> = 8...40

    /// Best guess at the depth of a Dock on `edge` set to `tileSize`: the
    /// measurement itself if this size has been seen before.
    func thickness(edge: DockEdge, tileSize: CGFloat) -> CGFloat? {
        guard let measured = depths[edge] else { return nil }
        let size = Int(tileSize.rounded())
        if let exact = measured[size] {
            return exact
        }
        // The Dock's padding changes in steps, not with every size, so the
        // nearest size that was measured most likely has the same.
        let nearest = measured.keys.min { (abs($0 - size), $0) < (abs($1 - size), $1) }
        guard let nearest, let depth = measured[nearest] else { return nil }
        let padding = depth - CGFloat(nearest)
        return Self.plausiblePadding.contains(padding) ? tileSize + padding : nil
    }

    /// Notes a measurement. Returns whether it was news.
    mutating func record(edge: DockEdge, tileSize: CGFloat, thickness: CGFloat) -> Bool {
        // A Dock much deeper than its setting allows was caught mid-resize,
        // before the setting caught up. Fine for now, not worth remembering.
        guard thickness - tileSize <= Self.plausiblePadding.upperBound else { return false }
        let size = Int(tileSize.rounded())
        guard depths[edge]?[size] != thickness else { return false }
        depths[edge, default: [:]][size] = thickness
        return true
    }

    private static let key = "dockDepths"

    static func load() -> DockCalibration {
        var calibration = DockCalibration()
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        for (edgeName, sizes) in stored {
            guard let edge = DockEdge(rawValue: edgeName) else { continue }
            for (sizeName, depth) in sizes {
                guard let size = Int(sizeName), size > 0, depth > 0 else { continue }
                calibration.depths[edge, default: [:]][size] = depth
            }
        }
        return calibration
    }

    func save() {
        var stored: [String: [String: Double]] = [:]
        for (edge, sizes) in depths {
            stored[edge.rawValue] = Dictionary(uniqueKeysWithValues: sizes.map { (String($0.key), Double($0.value)) })
        }
        UserDefaults.standard.set(stored, forKey: Self.key)
    }
}
