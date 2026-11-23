import AppKit

/// Watches the Dock and reports two things: its geometry, and (for an
/// auto-hiding Dock) whether the panel should currently be on screen.
///
/// macOS publishes no event for "the Dock just slid in", so this infers it
/// from two cheap signals:
///
/// - The pointer. The Dock only reveals while the pointer rests on its screen
///   edge, and hides once the pointer leaves the strip it occupies.
/// - The Dock's own window, which the window server lists as on screen only
///   while the Dock is showing. Reading that flag needs no permissions.
///
/// Polling adapts to what is happening: a slow tick while nothing can change,
/// a fast one only while the pointer is on the edge or the Dock is up.
@MainActor
final class DockTracker {
    private(set) var geometry: DockGeometry?
    private(set) var isPresent = false

    var onGeometryChange: (() -> Void)?
    var onPresenceChange: ((Bool) -> Void)?

    /// False when the panel should stay on screen regardless of the Dock.
    var followsDock = true
    /// True while a popover or menu is open; holds the panel in place.
    var isPinned = false
    /// Screen area of the revealed panel. Resting the pointer here keeps the
    /// panel up even if the Dock itself has gone.
    var hoverRegion = CGRect.null

    /// Ticks per second for each situation.
    private enum Rate: Double {
        /// Nothing to follow (Dock always visible): geometry checks only.
        case passive = 2
        /// Dock hidden, pointer far away. The Dock waits a moment before
        /// appearing, so even at this rate the edge is noticed in time.
        case distant = 10
        /// Dock hidden, pointer approaching its edge.
        case idle = 30
        /// Pointer on the Dock's edge: the Dock is about to appear.
        case armed = 120
        /// Pointer parked on the edge but no Dock (e.g. a full-screen video).
        case lingering = 20
        /// Panel showing: watch for the pointer leaving.
        case tracking = 60
    }

    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var rate: Rate?
    private var isPaused = false
    private var armedSince: CFTimeInterval?
    private var lastGeometryCheck: CFTimeInterval = 0
    private var lastFullGeometryCheck: CFTimeInterval = 0
    private var lastBar: CGRect?
    /// IDs of the Dock's windows, in the form the window-server query takes.
    private var dockWindows: CFArray?
    private var lastWindowLookup: CFTimeInterval = 0
    private var trackingTick = 0
    private var screenObserver: NSObjectProtocol?

    func start() {
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        setRate(.idle)
        timer.resume()
        refresh()
    }

    /// Stops all polling, e.g. while the display sleeps.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        rate = nil
        timer.schedule(deadline: .distantFuture)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        refresh()
    }

    /// Re-evaluates immediately, e.g. after a setting changes.
    func refresh() {
        guard !isPaused else { return }
        lastGeometryCheck = 0
        lastFullGeometryCheck = 0
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - lastGeometryCheck >= 0.5 {
            lastGeometryCheck = now
            // Reading the bar's rect is nearly free and changes whenever the
            // Dock moves, resizes or gains an icon, so it gates the full query
            // (which talks to the window server). The slow fallback catches
            // anything that leaves the rect untouched.
            let bar = CoreDock.rect
            if bar != lastBar || now - lastFullGeometryCheck >= 5 {
                lastBar = bar
                lastFullGeometryCheck = now
                let fresh = DockGeometry.current()
                if fresh != geometry {
                    // A Dock that moved to another screen or edge may be
                    // drawing in different windows.
                    if fresh?.screenFrame != geometry?.screenFrame || fresh?.edge != geometry?.edge {
                        lookUpDockWindows(force: true)
                    }
                    geometry = fresh
                    Log.debug("geometry \(String(describing: fresh))")
                    onGeometryChange?()
                }
            }
        }
        guard let dock = geometry else { return }

        guard dock.autohide, followsDock else {
            setRate(.passive)
            setPresent(true, because: "not following an auto-hiding Dock")
            return
        }

        let pointer = NSEvent.mouseLocation
        let depth = dock.depth(of: pointer)

        if isPresent {
            armedSince = nil
            setRate(.tracking)
            trackingTick &+= 1
            if isPinned { return }
            if depth > dock.thickness + 2 {
                // The pointer left the Dock's strip, which is exactly when the
                // Dock starts sliding away. Leave with it.
                setPresent(false, because: "pointer left the strip, depth \(Int(depth))")
            } else if trackingTick % 2 == 0, !hoverRegion.contains(pointer), !isDockWindowOnScreen() {
                setPresent(false, because: "Dock window gone, pointer depth \(Int(depth))")
            }
        } else if depth < 2 {
            let since = armedSince ?? now
            armedSince = since
            setRate(now - since < 1.5 ? .armed : .lingering)
            if isDockWindowOnScreen() {
                setPresent(true, because: "Dock window appeared \(Int((now - since) * 1000)) ms after the pointer reached the edge")
            }
        } else {
            armedSince = nil
            setRate(depth < 250 ? .idle : .distant)
        }
    }

    private func setPresent(_ present: Bool, because reason: @autoclosure () -> String) {
        guard present != isPresent else { return }
        isPresent = present
        Log.debug("\(present ? "show" : "hide"): \(reason())")
        onPresenceChange?(present)
    }

    private func setRate(_ newRate: Rate) {
        guard newRate != rate else { return }
        rate = newRate
        let interval = 1 / newRate.rawValue
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .nanoseconds(Int(interval * 0.2 * 1_000_000_000))
        )
    }

    // MARK: - Dock window

    /// Whether the window server is currently showing any of the Dock's windows.
    private func isDockWindowOnScreen() -> Bool {
        if dockWindows == nil {
            lookUpDockWindows()
        }
        guard let dockWindows else { return false }

        // Describing windows by ID answers for off-screen windows as well.
        // (Asking with `.optionIncludingWindow` returns nothing for a window
        // that is off screen, which looks the same as the window not existing.)
        guard let windows = CGWindowListCreateDescriptionFromArray(dockWindows) as? [[String: Any]],
              !windows.isEmpty
        else {
            // The windows no longer exist: the Dock restarted. Find its new ones.
            self.dockWindows = nil
            return false
        }
        return windows.contains { $0[kCGWindowIsOnscreen as String] as? Bool == true }
    }

    /// Finds the windows the Dock draws its bar in: the ones it owns at the
    /// dedicated Dock window level.
    ///
    /// Scanning every window on the system takes tens of milliseconds, so this
    /// runs at launch and when the Dock restarts or changes screen, never as
    /// part of the per-tick check.
    private func lookUpDockWindows(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastWindowLookup > 1 else { return }
        lastWindowLookup = now

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var ids: [UnsafeRawPointer?] = list.compactMap { window in
            guard window[kCGWindowOwnerName as String] as? String == "Dock",
                  window[kCGWindowLayer as String] as? Int == dockLevel,
                  let number = window[kCGWindowNumber as String] as? UInt
            else { return nil }
            // The query takes window IDs stored directly as the array's values.
            return UnsafeRawPointer(bitPattern: number)
        }
        dockWindows = ids.isEmpty ? nil : CFArrayCreate(kCFAllocatorDefault, &ids, ids.count, nil)
        Log.debug("found \(ids.count) Dock window(s) in \(Int((CACurrentMediaTime() - now) * 1000)) ms")
    }
}
