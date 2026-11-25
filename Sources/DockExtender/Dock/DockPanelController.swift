import AppKit
import ServiceManagement
import SwiftUI

/// Owns the panel: builds the tiles, keeps the window glued to the Dock, slides
/// it in and out with the Dock, and handles clicks and the right-click menu.
@MainActor
final class DockPanelController {
    private let settings: Settings
    private let allWidgets: [any DockWidget]
    private let scheduler = SampleScheduler()
    private let tracker = DockTracker()

    private let panel = DockPanel()
    private let slider: WindowSlider
    private let glass = NSGlassEffectView()
    private let strip = StripView()

    private var tileWidgets: [any DockWidget] = []
    private var tiles: [TileView] = []
    private var layout: PanelLayout?
    /// Set when a new layout arrives mid-slide; applied once the slide ends.
    private var needsRelayout = false
    private var isRevealed = false
    private var slideDuration = DockPreferences.slideDuration

    private var popover: NSPopover?
    private var popoverWidgetID: String?
    private var outsideClickMonitor: Any?
    private var isMenuOpen = false
    private var sleepObservers: [NSObjectProtocol] = []

    init(settings: Settings, widgets: [any DockWidget]) {
        self.settings = settings
        self.allWidgets = widgets
        self.slider = WindowSlider(window: panel)
    }

    func start() {
        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        strip.autoresizingMask = [.width, .height]
        glass.contentView = strip
        root.addSubview(glass)

        strip.onClick = { [weak self] in self?.closePopover() }
        strip.onMenu = { [weak self] event in self?.showMenu(for: event) }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        tracker.onGeometryChange = { [weak self] in self?.geometryChanged() }
        tracker.onPresenceChange = { [weak self] present in self?.setRevealed(present) }

        rebuildTiles()
        applyMode()
        scheduler.run(tileWidgets, intervalScale: settings.intervalScale)
        tracker.start()

        // Nothing to show or follow while the display is asleep.
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tracker.pause()
                    self?.scheduler.pause()
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduler.resume()
                    self?.tracker.resume()
                }
            },
        ]
    }

    /// Developer aid, see `Snapshot`: writes the tile and detail views to
    /// `url`, and the live panel window next to it.
    func writeSnapshots(to url: URL, completion: @escaping () -> Void) {
        Log.debug("window visible=\(panel.isVisible) frame=\(panel.frame) glass=\(glass.frame) strip=\(strip.frame)")
        scheduler.isPublishing = true
        let base = url.deletingPathExtension()
        Snapshot.write(widgets: allWidgets, to: url)
        Snapshot.capture(window: panel, to: base.appendingPathExtension("window.png"))

        // Exercise the click path too: open the first tile's popover and
        // capture it once it has finished appearing.
        guard panel.isVisible, let tile = tiles.first else {
            completion()
            return
        }
        togglePopover(for: tile)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                if let window = self?.popover?.contentViewController?.view.window {
                    Log.debug("popover frame=\(window.frame)")
                    Snapshot.capture(window: window, to: base.appendingPathExtension("popover.png"))
                }
                completion()
            }
        }
    }

    // MARK: - Reacting to changes

    private func settingsChanged() {
        rebuildTiles()
        scheduler.run(tileWidgets, intervalScale: settings.intervalScale)
        applyMode()
        relayout()
        tracker.refresh()
    }

    private func geometryChanged() {
        slideDuration = DockPreferences.slideDuration
        applyMode()
        relayout()
    }

    private func applyMode() {
        let follows = !settings.keepVisible
        tracker.followsDock = follows
        panel.setFollowsDock(follows && tracker.geometry?.autohide == true)
    }

    private func rebuildTiles() {
        let hidden = settings.hiddenWidgets
        let widgets = allWidgets.filter { !hidden.contains($0.info.id) }
        guard widgets.map({ $0.info.id }) != tileWidgets.map({ $0.info.id }) else { return }

        closePopover()
        tiles.forEach { $0.removeFromSuperview() }
        tileWidgets = widgets
        tiles = widgets.map { widget in
            let tile = TileView(widget: widget, scale: layout?.contentScale ?? 1)
            tile.onClick = { [weak self, weak tile] in
                guard let tile else { return }
                self?.togglePopover(for: tile)
            }
            tile.onMenu = { [weak self] event in self?.showMenu(for: event) }
            strip.addSubview(tile)
            return tile
        }
        layout = nil
    }

    private func relayout() {
        // Resizing the window under a running slide would make it jump, and
        // the tiles are about to move anyway: wait for the slide to finish.
        guard !slider.isRunning else {
            needsRelayout = true
            return
        }
        needsRelayout = false
        guard let dock = tracker.geometry else { return }
        let fresh = PanelLayout.make(
            dock: dock,
            side: settings.side,
            widthFactors: tileWidgets.map { $0.info.widthFactor }
        )
        guard fresh != layout else { return }
        Log.debug("layout shown=\(fresh.shownFrame) bar=\(fresh.barFrame) tiles=\(fresh.tileFrames.count) scale=\(fresh.contentScale)")

        closePopover()
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
        tracker.hoverRegion = fresh.shownFrame
        if isRevealed {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Sliding in and out

    private func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        if revealed {
            // Bring the tiles up to date before they slide into view.
            scheduler.isPublishing = true
        }
        guard let layout else { return }
        let screen = NSScreen.screens.first { $0.frame == tracker.geometry?.screenFrame }

        if revealed {
            if !panel.isVisible {
                panel.setFrame(layout.hiddenFrame, display: true)
                panel.orderFrontRegardless()
            }
            let started = CACurrentMediaTime()
            slider.slide(to: layout.shownFrame, duration: slideDuration, curve: .easeOut, on: screen) { [weak self] in
                Log.debug("slide in finished \(Int((CACurrentMediaTime() - started) * 1000)) ms after the decision to show")
                self?.relayoutIfNeeded()
            }
        } else {
            closePopover()
            tiles.forEach { $0.setHighlighted(false) }
            slider.slide(to: layout.hiddenFrame, duration: slideDuration, curve: .easeIn, on: screen) { [weak self] in
                guard let self, !self.isRevealed else { return }
                // Once ordered out the window costs nothing to composite, and
                // the views stop updating until the next reveal.
                self.panel.orderOut(nil)
                self.scheduler.isPublishing = false
                self.slideDuration = DockPreferences.slideDuration
                self.relayoutIfNeeded()
            }
        }
    }

    private func relayoutIfNeeded() {
        if needsRelayout {
            relayout()
        }
    }

    // MARK: - Detail popover

    private func togglePopover(for tile: TileView) {
        let id = tile.widgetID
        let wasOpen = popoverWidgetID == id
        closePopover()
        guard !wasOpen, let layout, let widget = allWidgets.first(where: { $0.info.id == id }) else { return }

        let content = NSHostingController(rootView: widget.detailView)
        content.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = content
        // The app is never active, so AppKit's own "click elsewhere to dismiss"
        // does not fire; closing is handled by the monitor below.
        popover.behavior = .applicationDefined

        let edge: NSRectEdge
        switch layout.edge {
        case .bottom: edge = .maxY
        case .left: edge = .maxX
        case .right: edge = .minX
        }
        popover.show(relativeTo: tile.bounds, of: tile, preferredEdge: edge)

        self.popover = popover
        popoverWidgetID = id
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        updatePinned()
    }

    private func closePopover() {
        guard let popover else { return }
        self.popover = nil
        popoverWidgetID = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        popover.close()
        updatePinned()
    }

    /// Hold the panel in place while something that belongs to it is open,
    /// even though the pointer has left the Dock's strip.
    private func updatePinned() {
        tracker.isPinned = popover != nil || isMenuOpen
    }

    // MARK: - Right-click menu

    private func showMenu(for event: NSEvent) {
        guard let view = panel.contentView else { return }
        closePopover()
        let menu = buildMenu()
        isMenuOpen = true
        updatePinned()
        // Runs its own event loop and returns once the menu closes.
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        isMenuOpen = false
        updatePinned()
    }

    private func buildMenu() -> NSMenu {
        let settings = self.settings
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Widgets
        let hidden = settings.hiddenWidgets
        let shownCount = allWidgets.filter { !hidden.contains($0.info.id) }.count
        menu.addItem(.sectionHeader(title: "Widgets"))
        for widget in allWidgets {
            let info = widget.info
            let isShown = !hidden.contains(info.id)
            let item = ActionMenuItem(info.title, checked: isShown) {
                var hidden = settings.hiddenWidgets
                if isShown {
                    hidden.insert(info.id)
                } else {
                    hidden.remove(info.id)
                }
                settings.hiddenWidgets = hidden
            }
            item.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)
            // The panel is the app's only UI, so the last widget cannot be removed.
            item.isEnabled = !(isShown && shownCount == 1)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Position
        let isBottom = (tracker.geometry?.edge ?? .bottom) == .bottom
        let position = NSMenu()
        position.addItem(ActionMenuItem(isBottom ? "Left of Dock" : "Above Dock", checked: settings.side == .leading) {
            settings.side = .leading
        })
        position.addItem(ActionMenuItem(isBottom ? "Right of Dock" : "Below Dock", checked: settings.side == .trailing) {
            settings.side = .trailing
        })
        menu.addItem(submenu("Position", position))

        // Update speed
        let speeds: [(title: String, scale: Double)] = [
            ("Half a Second", 0.5), ("Second", 1), ("2 Seconds", 2), ("5 Seconds", 5),
        ]
        let speed = NSMenu()
        for option in speeds {
            speed.addItem(ActionMenuItem(option.title, checked: settings.intervalScale == option.scale) {
                settings.intervalScale = option.scale
            })
        }
        menu.addItem(submenu("Update Every", speed))

        if tracker.geometry?.autohide == true {
            menu.addItem(ActionMenuItem("Stay Visible When Dock Hides", checked: settings.keepVisible) {
                settings.keepVisible.toggle()
            })
        }
        if Bundle.main.bundleIdentifier != nil {
            menu.addItem(launchAtLoginItem())
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Dock Extender") {
            NSApp.terminate(nil)
        })
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let isEnabled = SMAppService.mainApp.status == .enabled
        return ActionMenuItem("Launch at Login", checked: isEnabled) {
            do {
                if isEnabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
