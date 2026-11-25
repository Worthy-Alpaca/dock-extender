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
///
/// How deep an auto-hiding Dock is cannot be read from anywhere either, so
/// while the Dock is up the tracker measures it (see `DockProbe`) and corrects
/// the geometry whenever the Dock turns out to be a different size.
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

    /// Timing of the Dock depth measurements, in seconds.
    private enum Probe {
        /// After the Dock appears, before the first reading: it is sliding in.
        static let settle: CFTimeInterval = 0.3
        /// Between a reading and the one that confirms it.
        static let confirm: CFTimeInterval = 0.1
        /// Between routine readings once the depth is confirmed.
        static let routine: CFTimeInterval = 2
    }

    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var rate: Rate?
    private var isPaused = false
    private var armedSince: CFTimeInterval?
    private var lastGeometryCheck: CFTimeInterval = 0
    private var lastBar: CGRect?
    /// IDs of the Dock's windows, in the form the window-server query takes.
    private var dockWindows: CFArray?
    /// The same IDs, for comparing against hit-test results.
    private var dockWindowNumbers: Set<Int> = []
    private var lastWindowLookup: CFTimeInterval = 0
    /// Depths the Dock has been measured at; outlives the app.
    private var calibration = DockCalibration.load()
    /// A depth reading waiting for a second one to confirm it.
    private var pendingReach: CGFloat?
    private var nextProbe: CFTimeInterval = 0
    private var hasLoggedReach = false
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
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // Reading the bar's rect is nearly free and changes whenever the Dock
        // moves, resizes or gains an icon, so every tick looks at it and only
        // a change sets off the full query (which may talk to the window
        // server). The slow fallback catches anything that leaves the rect
        // untouched.
        let bar = CoreDock.rect
        if bar != lastBar || now - lastGeometryCheck >= 5 {
            lastBar = bar
            lastGeometryCheck = now
            updateGeometry(at: now)
        }
        measureDock(at: now)
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
            if depth > dock.thickness + 2, NSEvent.pressedMouseButtons == 0 {
                // The pointer left the Dock's strip, which is exactly when the
                // Dock starts sliding away. Leave with it. Not during a drag,
                // though: the Dock stays up for those (resizing it by its
                // divider is one), so then only its window going away counts.
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
        // A Dock that has just appeared is still sliding in: let it arrive
        // before measuring it.
        pendingReach = nil
        nextProbe = CACurrentMediaTime() + Probe.settle
        hasLoggedReach = false
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

    // MARK: - Geometry

    private func updateGeometry(at now: CFTimeInterval) {
        let fresh = DockGeometry.current(calibration: calibration)
        guard fresh != geometry else { return }
        // A Dock that moved to another screen or edge may be drawing in
        // different windows.
        if fresh?.screenFrame != geometry?.screenFrame || fresh?.edge != geometry?.edge {
            lookUpDockWindows(force: true)
        }
        geometry = fresh
        // Whatever changed may have changed the Dock's depth as well, so
        // measure again now instead of at the next routine reading.
        pendingReach = nil
        nextProbe = min(nextProbe, now)
        Log.debug("geometry \(String(describing: fresh))")
        onGeometryChange?()
    }

    /// Measures how deep the Dock is while it is on screen, and corrects the
    /// geometry once two readings in a row agree. (One reading is not enough:
    /// taken while the Dock slides in or out, or while it is being resized, it
    /// catches the Dock on the way to somewhere else.)
    private func measureDock(at now: CFTimeInterval) {
        // Only an auto-hiding Dock needs this; one that is always showing
        // reports its depth through the screen space reserved for it.
        guard isPresent, now >= nextProbe, let dock = geometry, dock.autohide else { return }
        nextProbe = now + Probe.confirm

        // Magnified icons reach beyond the Dock, so with magnification on
        // only measure while the pointer is well clear of it.
        if CoreDock.magnifies, dock.isNear(NSEvent.mouseLocation) {
            pendingReach = nil
            return
        }
        guard isDockWindowOnScreen(), let reach = DockProbe.reach(of: dock, windows: dockWindowNumbers) else {
            pendingReach = nil
            return
        }
        guard reach == pendingReach else {
            pendingReach = reach
            return
        }
        nextProbe = now + Probe.routine

        if calibration.record(edge: dock.edge, tileSize: dock.tileSize, thickness: reach) {
            calibration.save()
        }
        guard reach != dock.thickness else {
            if !hasLoggedReach {
                hasLoggedReach = true
                Log.debug("Dock measured \(reach) pt deep, as expected")
            }
            return
        }
        Log.debug("Dock measured \(reach) pt deep, not the \(dock.thickness) expected")
        var corrected = dock
        corrected.thickness = reach
        geometry = corrected
        onGeometryChange?()
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
            dockWindowNumbers = []
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
        let numbers: [UInt] = list.compactMap { window in
            guard window[kCGWindowOwnerName as String] as? String == "Dock",
                  window[kCGWindowLayer as String] as? Int == dockLevel
            else { return nil }
            return window[kCGWindowNumber as String] as? UInt
        }
        // The query takes window IDs stored directly as the array's values.
        var ids = numbers.map { UnsafeRawPointer(bitPattern: $0) }
        dockWindows = ids.isEmpty ? nil : CFArrayCreate(kCFAllocatorDefault, &ids, ids.count, nil)
        dockWindowNumbers = Set(numbers.map { Int($0) })
        Log.debug("found \(ids.count) Dock window(s) in \(Int((CACurrentMediaTime() - now) * 1000)) ms")
    }
}
