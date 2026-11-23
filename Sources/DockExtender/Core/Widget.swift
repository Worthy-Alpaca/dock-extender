import SwiftUI

/// Static description of a widget.
struct WidgetInfo: Sendable {
    /// Stable identifier, used to remember whether the widget is switched on.
    let id: String
    /// Name shown in the right-click menu.
    let title: String
    /// SF Symbol shown next to the title.
    let symbol: String
    /// Seconds between calls to `read()`.
    var interval: TimeInterval = 1
    /// Tile width as a multiple of the Dock icon size (bottom Dock only;
    /// tiles are always square in a vertical Dock).
    var widthFactor: CGFloat = 1
}

/// One tile in the panel.
///
/// A widget splits its work in two so the UI never waits on the system:
/// `read()` runs on a background queue and gathers numbers, `apply(_:)` runs on
/// the main actor and publishes them to the views.
///
/// To add a widget: create a type conforming to this protocol and list it in
/// `WidgetRegistry.makeAll()`.
@MainActor
protocol DockWidget: AnyObject, Sendable {
    associatedtype Reading: Sendable
    associatedtype Tile: View
    associatedtype Detail: View

    var info: WidgetInfo { get }

    /// Collects one reading. Called on the sampling queue, never on the main thread.
    nonisolated func read() -> Reading

    /// Publishes a reading to the widget's observable state.
    func apply(_ reading: Reading)

    /// Compact view shown in the panel. Sized to roughly one Dock icon; scale
    /// fonts and spacing with the `tileScale` environment value.
    @ViewBuilder var tile: Tile { get }

    /// Larger view shown in a popover when the tile is clicked.
    @ViewBuilder var detail: Detail { get }
}

extension DockWidget {
    /// Scheduler entry point: read on the calling (background) queue, then hop
    /// to the main actor to publish. The gate delays publishing while the
    /// panel is off screen.
    nonisolated func refresh(through gate: UpdateGate) {
        let reading = read()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                gate.submit { self.apply(reading) }
            }
        }
    }

    var tileView: AnyView { AnyView(tile) }
    var detailView: AnyView { AnyView(detail) }
}

private struct TileScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 1.0 when a tile is drawn at its design size (57 pt); tiles multiply
    /// their font sizes and paddings by this.
    var tileScale: CGFloat {
        get { self[TileScaleKey.self] }
        set { self[TileScaleKey.self] = newValue }
    }
}
