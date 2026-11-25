import AppKit
import SwiftUI

/// Hosts one widget's SwiftUI tile and gives it Dock-icon behaviour: a hover
/// highlight, click to open details, right-click for the menu. Buttons a
/// widget puts in its tile (see `TileControl`) get the same treatment in
/// miniature.
///
/// Mouse handling lives here in AppKit rather than in SwiftUI gestures because
/// the panel never becomes the key window, and AppKit delivers the first click
/// to a non-key window reliably.
final class TileView: NSView {
    let widgetID: String
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private let widget: any DockWidget
    private let content: AnyView
    private let host: NSHostingView<AnyView>
    private let highlight = CALayer()
    /// Highlight for the button under the pointer.
    private let controlHighlight = CALayer()
    private var scale: CGFloat
    private var pressed = false
    /// Presses and drags on the widget's own controls.
    private var mouse = ControlMouse()

    init(widget: any DockWidget, scale: CGFloat) {
        self.widget = widget
        widgetID = widget.info.id
        content = widget.tileView
        self.scale = scale
        host = NSHostingView(rootView: Self.root(content, scale: scale))
        super.init(frame: .zero)

        wantsLayer = true
        highlight.backgroundColor = NSColor(white: 0.5, alpha: 0.22).cgColor
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        controlHighlight.backgroundColor = highlight.backgroundColor
        controlHighlight.cornerCurve = .continuous
        controlHighlight.opacity = 0
        layer?.addSublayer(controlHighlight)

        // The tile's frame is set by PanelLayout; the SwiftUI content must fill
        // it rather than push its own ideal size back into AppKit.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(widget.info.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setScale(_ newScale: CGFloat) {
        guard abs(newScale - scale) > 0.001 else { return }
        scale = newScale
        host.rootView = Self.root(content, scale: newScale)
    }

    func setHighlighted(_ highlighted: Bool) {
        highlight.opacity = highlighted ? 1 : 0
        if !highlighted {
            controlHighlight.opacity = 0
        }
    }

    // MARK: - Controls in the tile

    /// Where the event happened, in the coordinates the controls use.
    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        // The view's origin is at the bottom left, the controls' at the top.
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private var controls: [TileControl] {
        widget.controls(in: bounds.size, scale: scale)
    }

    /// Lights up the button under the pointer, or else the whole tile.
    private func updateHover(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let controls = controls
        if let index = ControlMouse.index(at: location(of: event), in: controls), case .button = controls[index].kind {
            let frame = controls[index].frame
            controlHighlight.frame = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
            controlHighlight.cornerRadius = min(frame.width, frame.height) * 0.3
            controlHighlight.backgroundColor = NSColor(white: 0.5, alpha: mouse.pressed == index ? 0.4 : 0.22).cgColor
            controlHighlight.opacity = 1
            highlight.opacity = 0
        } else {
            controlHighlight.opacity = 0
            highlight.opacity = 1
        }
        CATransaction.commit()
    }

    private static func root(_ content: AnyView, scale: CGFloat) -> AnyView {
        AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.tileScale, scale)
        )
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        host.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        highlight.cornerRadius = min(bounds.width, bounds.height) * 0.23
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Mouse

    /// Claim every event inside the tile so the SwiftUI content never sees them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onMenu?(event)
        } else if mouse.down(at: location(of: event), in: controls) {
            updateHover(with: event)
        } else {
            pressed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouse.dragged(to: location(of: event), in: controls)
    }

    override func mouseUp(with event: NSEvent) {
        if mouse.up(at: location(of: event), in: controls) {
            updateHover(with: event)
            return
        }
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

/// The bar's background: catches clicks that miss every tile.
final class StripView: NSView {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onMenu?(event)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}
