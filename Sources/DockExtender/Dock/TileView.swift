import AppKit
import SwiftUI

/// Hosts one widget's SwiftUI tile and gives it Dock-icon behaviour: a hover
/// highlight, click to open details, right-click for the menu.
///
/// Mouse handling lives here in AppKit rather than in SwiftUI gestures because
/// the panel never becomes the key window, and AppKit delivers the first click
/// to a non-key window reliably.
final class TileView: NSView {
    let widgetID: String
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private let content: AnyView
    private let host: NSHostingView<AnyView>
    private let highlight = CALayer()
    private var scale: CGFloat
    private var pressed = false

    init(widget: any DockWidget, scale: CGFloat) {
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
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Mouse

    /// Claim every event inside the tile so the SwiftUI content never sees them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onMenu?(event)
        } else {
            pressed = true
        }
    }

    override func mouseUp(with event: NSEvent) {
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
