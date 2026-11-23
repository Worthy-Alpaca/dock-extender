import AppKit

/// The borderless window that carries the widget bar.
///
/// It never takes focus (clicking a tile must not pull you out of the app you
/// are working in) and floats just above the Dock's window level.
final class DockPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise nudge the window back on screen, which defeats
    /// sliding it past the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// `followsDock`: appear with the Dock everywhere it appears, including
    /// over full-screen apps. Otherwise stay out of full-screen spaces.
    func setFollowsDock(_ followsDock: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if followsDock {
            behavior.insert(.fullScreenAuxiliary)
        }
        collectionBehavior = behavior
    }
}

/// Moves a window between two frames in step with the display's refresh.
///
/// The window itself moves (rather than a layer inside it) so the glass
/// material keeps sampling the right backdrop, and so an animation can be
/// reversed mid-flight from wherever the window currently is.
@MainActor
final class WindowSlider: NSObject {
    enum Curve {
        case easeOut, easeIn

        func value(at progress: Double) -> Double {
            switch self {
            case .easeOut: return 1 - pow(1 - progress, 3)
            case .easeIn: return pow(progress, 3)
            }
        }
    }

    private let window: NSWindow
    private var link: CADisplayLink?
    private var from = CGRect.zero
    private var to = CGRect.zero
    private var startTime: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var curve = Curve.easeOut
    private var completion: (() -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    func slide(
        to frame: CGRect,
        duration: TimeInterval,
        curve: Curve,
        on screen: NSScreen?,
        completion: (() -> Void)? = nil
    ) {
        cancel()
        guard duration > 0.01, let screen, window.frame != frame else {
            window.setFrame(frame, display: true)
            completion?()
            return
        }
        from = window.frame
        to = frame
        self.duration = duration
        self.curve = curve
        self.completion = completion
        startTime = CACurrentMediaTime()

        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops any running animation where it is, without calling its completion.
    func cancel() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - startTime) / duration)
        let eased = curve.value(at: progress)
        let origin = CGPoint(
            x: from.minX + (to.minX - from.minX) * eased,
            y: from.minY + (to.minY - from.minY) * eased
        )
        window.setFrameOrigin(origin)

        if progress >= 1 {
            let finished = completion
            cancel()
            window.setFrame(to, display: true)
            finished?()
        }
    }
}
