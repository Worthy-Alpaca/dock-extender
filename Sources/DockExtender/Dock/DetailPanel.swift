import AppKit
import SwiftUI

/// The card that opens next to a tile when the tile is clicked.
///
/// It looks like a popover but is a window of the app's own, for one reason:
/// clicking in a popover activates the app, which takes the keyboard away
/// from whatever the user was working in. This window never activates
/// anything (it is the same kind of panel as the bars), so a card can hold
/// controls and still leave the user where they were.
@MainActor
final class DetailPanel {
    private enum Metric {
        /// Between the bar and the card.
        static let gap: CGFloat = 8
        static let cornerRadius: CGFloat = 12
        /// Closest the card comes to the edge of the screen.
        static let screenMargin: CGFloat = 8
    }

    private let panel = CardWindow()
    private let backdrop = NSVisualEffectView()
    private var card: DetailView?
    /// The tile the card belongs to and the bar it is in, on screen.
    private var anchor: (tile: CGRect, bar: CGRect, edge: DockEdge)?

    init() {
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // Rounds the corners of the blur itself, and with it the window's
        // shadow.
        backdrop.maskImage = Self.mask(radius: Metric.cornerRadius)
        panel.contentView = backdrop
    }

    var isOpen: Bool { card != nil }
    var window: NSWindow { panel }

    /// Shows `widget`'s detail view next to its tile.
    func open(_ widget: any DockWidget, tile: CGRect, bar: CGRect, edge: DockEdge) {
        close()
        let card = DetailView(widget: widget)
        card.onResize = { [weak self] in self?.place() }
        card.autoresizingMask = [.width, .height]
        backdrop.addSubview(card)
        self.card = card
        anchor = (tile, bar, edge)
        place()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let card else { return }
        self.card = nil
        anchor = nil
        panel.orderOut(nil)
        card.removeFromSuperview()
    }

    /// Sizes the window to the card and puts it beside the bar, level with
    /// the tile. Runs again whenever the card's contents change size, keeping
    /// the side that faces the bar where it is.
    private func place() {
        guard let card, let anchor else { return }
        let size = card.contentSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.bar) } ?? NSScreen.screens.first
        let bounds = (screen?.frame ?? anchor.bar).insetBy(dx: Metric.screenMargin, dy: Metric.screenMargin)

        var origin: CGPoint
        switch anchor.edge {
        case .bottom:
            origin = CGPoint(x: anchor.tile.midX - size.width / 2, y: anchor.bar.maxY + Metric.gap)
        case .left:
            origin = CGPoint(x: anchor.bar.maxX + Metric.gap, y: anchor.tile.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: anchor.bar.minX - Metric.gap - size.width, y: anchor.tile.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))

        let frame = CGRect(origin: origin, size: size)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        card.frame = backdrop.bounds
        panel.invalidateShadow()
    }

    /// A rounded rectangle that stretches to any size.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless, never key, never activating: clicks land in it without the app
/// coming to the front. Sits just above the bars.
private final class CardWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts a widget's SwiftUI detail view and handles the mouse for the
/// controls the widget puts in it, the way `TileView` does for a tile.
final class DetailView: NSView {
    /// The contents changed size.
    var onResize: (() -> Void)?

    private let widget: any DockWidget
    private let host: NSHostingView<AnyView>
    /// Highlight for the button under the pointer.
    private let highlight = CALayer()
    private var mouse = ControlMouse()
    /// Size the SwiftUI content asks for, once it has been laid out.
    private var reportedSize: CGSize?

    init(widget: any DockWidget) {
        self.widget = widget
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)

        wantsLayer = true
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        // The content takes the size it wants and says what that is; the
        // window is then made to fit.
        host.rootView = AnyView(
            widget.detailView
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.contentResized(to: size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The size the card wants to be.
    var contentSize: CGSize {
        reportedSize ?? host.fittingSize
    }

    private func contentResized(to size: CGSize) {
        guard size != reportedSize else { return }
        reportedSize = size
        onResize?()
    }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    // MARK: - Mouse

    private var controls: [TileControl] {
        widget.detailControls(in: bounds.size)
    }

    /// Where the event happened, in the coordinates the controls use.
    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        // The view's origin is at the bottom left, the controls' at the top.
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    /// Claim every event so the SwiftUI content never sees them: the window
    /// is never key, and AppKit delivers clicks to a non-key window reliably.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    /// Lights up the button under the pointer, darker while it is held down.
    private func updateHover(with event: NSEvent?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let controls = controls
        if let event,
           let index = ControlMouse.index(at: location(of: event), in: controls),
           case .button = controls[index].kind {
            let frame = controls[index].frame
            highlight.frame = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
            highlight.cornerRadius = min(frame.width, frame.height) * 0.3
            highlight.backgroundColor = NSColor(white: 0.5, alpha: mouse.pressed == index ? 0.4 : 0.22).cgColor
            highlight.opacity = 1
        } else {
            highlight.opacity = 0
        }
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { updateHover(with: nil) }

    override func mouseDown(with event: NSEvent) {
        _ = mouse.down(at: location(of: event), in: controls)
        updateHover(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouse.dragged(to: location(of: event), in: controls)
    }

    override func mouseUp(with event: NSEvent) {
        _ = mouse.up(at: location(of: event), in: controls)
        updateHover(with: event)
    }
}
