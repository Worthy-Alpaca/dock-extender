import AppKit
import SwiftUI

/// One bar next to the Dock: the window, its glass, the tiles of one widget
/// group and their detail card.
///
/// What the bars have in common (where the Dock is, when to slide, the
/// right-click menu) is decided by `DockPanelController`, which tells each bar
/// where to sit and when to move.
@MainActor
final class BarController {
    let group: WidgetGroup

    /// A right-click anywhere on the bar.
    var onMenu: ((NSEvent) -> Void)?
    /// About to open a detail card; other bars close theirs.
    var onCardWillOpen: (() -> Void)?
    /// A card opened or closed.
    var onCardChange: (() -> Void)?

    private let panel = DockPanel()
    private let slider: WindowSlider
    private let glass = NSGlassEffectView()
    private let strip = StripView()

    private var tileWidgets: [any DockWidget] = []
    private var tiles: [TileView] = []
    private(set) var layout: PanelLayout?
    private(set) var isRevealed = false

    private let card = DetailPanel()
    /// The widget whose card is open.
    private var cardWidgetID: String?
    private var outsideClickMonitor: Any?

    init(group: WidgetGroup) {
        self.group = group
        self.slider = WindowSlider(window: panel)

        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        strip.autoresizingMask = [.width, .height]
        glass.contentView = strip
        root.addSubview(glass)

        strip.onClick = { [weak self] in self?.closeCard() }
        strip.onMenu = { [weak self] event in self?.onMenu?(event) }
    }

    /// The widgets currently shown as tiles.
    var widgets: [any DockWidget] { tileWidgets }
    var window: NSWindow { panel }
    /// The view a context menu is shown for.
    var menuAnchor: NSView? { panel.contentView }
    var isSliding: Bool { slider.isRunning }
    var hasCard: Bool { cardWidgetID != nil }

    func setFollowsDock(_ followsDock: Bool) {
        panel.setFollowsDock(followsDock)
    }

    // MARK: - Tiles and layout

    /// Shows a tile for every widget of the group that is not in `hidden`.
    func showWidgets(except hidden: Set<String>) {
        let widgets = group.widgets.filter { !hidden.contains($0.info.id) }
        guard widgets.map({ $0.info.id }) != tileWidgets.map({ $0.info.id }) else { return }

        closeCard()
        tiles.forEach { $0.removeFromSuperview() }
        tileWidgets = widgets
        tiles = widgets.map { widget in
            let tile = TileView(widget: widget, scale: layout?.contentScale ?? 1)
            tile.onClick = { [weak self, weak tile] in
                guard let tile else { return }
                self?.toggleCard(for: tile)
            }
            tile.onMenu = { [weak self] event in self?.onMenu?(event) }
            strip.addSubview(tile)
            return tile
        }
        layout = nil
    }

    /// Puts the bar where `fresh` says. Not to be called mid-slide: resizing
    /// the window under a running slide makes it jump.
    func apply(_ fresh: PanelLayout) {
        guard fresh != layout else { return }
        Log.debug("\(group.id) layout shown=\(fresh.shownFrame) bar=\(fresh.barFrame) tiles=\(fresh.tileFrames.count) scale=\(fresh.contentScale)")

        closeCard()
        layout = fresh
        slider.cancel()
        panel.setFrame(isRevealed ? fresh.shownFrame : fresh.hiddenFrame, display: false)
        glass.frame = fresh.barFrame
        glass.cornerRadius = fresh.cornerRadius
        strip.frame = glass.bounds
        for (index, tile) in tiles.enumerated() {
            if index < fresh.tileFrames.count {
                tile.isHidden = false
                tile.frame = fresh.tileFrames[index]
                tile.setScale(fresh.contentScale)
            } else {
                tile.isHidden = true
            }
        }
        if isRevealed {
            panel.orderFrontRegardless()
        }
    }

    /// Takes the bar off screen for good: it has been switched off.
    func remove() {
        closeCard()
        slider.cancel()
        panel.orderOut(nil)
        isRevealed = false
        layout = nil
    }

    // MARK: - Sliding in and out

    /// Slides the bar in or out. `completion` runs once it has arrived, unless
    /// the slide was overtaken by another.
    func setRevealed(_ revealed: Bool, duration: TimeInterval, on screen: NSScreen?, completion: @escaping () -> Void) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        guard let layout else { return }

        if revealed {
            if !panel.isVisible {
                panel.setFrame(layout.hiddenFrame, display: true)
                panel.orderFrontRegardless()
            }
            let started = CACurrentMediaTime()
            let id = group.id
            slider.slide(to: layout.shownFrame, duration: duration, curve: .easeOut, on: screen) {
                Log.debug("\(id) slide in finished \(Int((CACurrentMediaTime() - started) * 1000)) ms after the decision to show")
                completion()
            }
        } else {
            closeCard()
            tiles.forEach { $0.setHighlighted(false) }
            slider.slide(to: layout.hiddenFrame, duration: duration, curve: .easeIn, on: screen) { [weak self] in
                guard let self, !self.isRevealed else { return }
                // Once ordered out the window costs nothing to composite.
                self.panel.orderOut(nil)
                completion()
            }
        }
    }

    // MARK: - Detail card

    /// Opens the detail card of the first tile, also while the bar is off
    /// screen. For the snapshot tool.
    func openFirstCard() -> NSWindow? {
        guard let tile = tiles.first else { return nil }
        if cardWidgetID != tile.widgetID {
            toggleCard(for: tile)
        }
        return hasCard ? card.window : nil
    }

    private func toggleCard(for tile: TileView) {
        let id = tile.widgetID
        let wasOpen = cardWidgetID == id
        closeCard()
        guard !wasOpen, let layout,
              let index = tiles.firstIndex(where: { $0 === tile }), index < layout.tileFrames.count,
              let widget = tileWidgets.first(where: { $0.info.id == id })
        else { return }
        onCardWillOpen?()

        // Where the bar and the tile are on screen when the bar is showing.
        let bar = layout.barFrame.offsetBy(dx: layout.shownFrame.minX, dy: layout.shownFrame.minY)
        let tileFrame = layout.tileFrames[index].offsetBy(dx: bar.minX, dy: bar.minY)
        card.open(widget, tile: tileFrame, bar: bar, edge: layout.edge)
        cardWidgetID = id

        // The app is never active, so nothing tells it about clicks elsewhere
        // by itself; this does. (Clicks on the app's own windows do not come
        // through here, which is what lets the card be clicked.)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCard() }
        }
        onCardChange?()
    }

    func closeCard() {
        guard cardWidgetID != nil else { return }
        cardWidgetID = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        card.close()
        onCardChange?()
    }
}
