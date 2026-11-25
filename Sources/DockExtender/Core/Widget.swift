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
    /// tiles are always square in a vertical Dock). A tile wider than one
    /// icon gets less when room is short, down to one icon's width, so it
    /// must be able to draw itself that narrow.
    var widthFactor: CGFloat = 1
}

/// A part of a tile, or of a detail card, that takes the mouse itself. The
/// widget draws it as part of its view; the view hosting that handles the
/// mouse, as it does for the tile as a whole.
struct TileControl {
    enum Kind {
        /// Acts when clicked.
        case button(@MainActor () -> Void)
        /// Follows the mouse while it is held down. Called with the pointer's
        /// place in the tile when the mouse goes down, whenever it moves, and
        /// when it comes up, also when it has strayed outside the control.
        case slider(@MainActor (CGPoint) -> Void)
    }

    /// Where it is in the tile or card, in the coordinates SwiftUI lays that
    /// out in: points, origin at the top left. Mouse positions use the same.
    let frame: CGRect
    let kind: Kind
}

/// One tile in a bar.
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

    /// Larger view shown in a card next to the tile when the tile is clicked.
    @ViewBuilder var detail: Detail { get }

    /// The controls in the tile when it is drawn at `size`. Most widgets have
    /// none, and need not implement this.
    func controls(in size: CGSize, scale: CGFloat) -> [TileControl]

    /// The controls in the detail card when it is drawn at `size`. Likewise.
    func detailControls(in size: CGSize) -> [TileControl]
}

extension DockWidget {
    func controls(in size: CGSize, scale: CGFloat) -> [TileControl] { [] }
    func detailControls(in size: CGSize) -> [TileControl] { [] }

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
