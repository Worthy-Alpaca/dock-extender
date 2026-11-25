import AppKit
import ServiceManagement
import SwiftUI

/// Runs the bars: one per widget group, each its own window next to the Dock.
///
/// Everything the bars share lives here: following the Dock, sampling the
/// widgets, deciding where each bar sits, sliding them in and out together,
/// and the right-click menu.
@MainActor
final class DockPanelController {
    private let settings: Settings
    private let bars: [BarController]
    private let scheduler = SampleScheduler()
    private let tracker = DockTracker()

    private var isRevealed = false
    /// Set when a new layout arrives mid-slide; applied once the slide ends.
    private var needsRelayout = false
    private var slideDuration = DockPreferences.slideDuration
    private var isMenuOpen = false
    private var sleepObservers: [NSObjectProtocol] = []

    init(settings: Settings, groups: [WidgetGroup]) {
        self.settings = settings
        self.bars = groups.map(BarController.init)
    }

    func start() {
        for bar in bars {
            bar.onMenu = { [weak self, weak bar] event in
                guard let bar else { return }
                self?.showMenu(for: event, on: bar)
            }
            bar.onCardWillOpen = { [weak self, weak bar] in
                self?.bars.filter { $0 !== bar }.forEach { $0.closeCard() }
            }
            bar.onCardChange = { [weak self] in self?.updatePinned() }
        }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        tracker.onGeometryChange = { [weak self] in self?.geometryChanged() }
        tracker.onPresenceChange = { [weak self] present in self?.setRevealed(present) }

        showWidgets()
        applyMode()
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
    /// `url`, and next to it each bar's live window and the card of its first
    /// tile as the window server draws them.
    func writeSnapshots(to url: URL, completion: @escaping () -> Void) {
        scheduler.isPublishing = true
        let base = url.deletingPathExtension()
        Snapshot.write(widgets: bars.flatMap { $0.group.widgets }, to: url)

        // One bar after the other, since only one card is open at a time.
        // Each card gets a moment to fade in and take its final size.
        func capture(_ remaining: ArraySlice<BarController>) {
            guard let bar = remaining.first else {
                completion()
                return
            }
            let name = bar.group.id
            Log.debug("\(name) window visible=\(bar.window.isVisible) frame=\(bar.window.frame)")
            Snapshot.capture(window: bar.window, to: base.appendingPathExtension("\(name).bar.png"))
            guard let card = bar.openFirstCard() else {
                capture(remaining.dropFirst())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    Log.debug("\(name) card frame=\(card.frame)")
                    Snapshot.capture(window: card, to: base.appendingPathExtension("\(name).card.png"))
                    bar.closeCard()
                    capture(remaining.dropFirst())
                }
            }
        }
        capture(shownBars[...])
    }

    // MARK: - Bars

    /// The bars that are switched on.
    private var shownBars: [BarController] {
        let hidden = settings.hiddenBars
        return bars.filter { !hidden.contains($0.group.id) }
    }

    /// Which end of the Dock a bar sits at. Until the user chooses, the first
    /// bar takes the Trash end and every other bar the end opposite the first,
    /// so that a new bar gets a place of its own.
    private func side(of bar: BarController) -> Settings.Side {
        if let chosen = settings.side(ofBar: bar.group.id) {
            return chosen
        }
        guard let first = bars.first, bar !== first else { return .trailing }
        return side(of: first).opposite
    }

    /// Gives every bar its tiles and tells the scheduler what to sample.
    private func showWidgets() {
        let hidden = settings.hiddenWidgets
        let shown = shownBars
        for bar in bars {
            if shown.contains(where: { $0 === bar }) {
                bar.showWidgets(except: hidden)
            } else {
                bar.remove()
            }
        }
        scheduler.run(shown.flatMap(\.widgets), intervalScale: settings.intervalScale)
    }

    // MARK: - Reacting to changes

    private func settingsChanged() {
        showWidgets()
        applyMode()
        relayout()
        // A bar that was just switched on joins the others where they are.
        slide()
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
        bars.forEach { $0.setFollowsDock(follows && tracker.geometry?.autohide == true) }
    }

    /// Places the bars: at each end of the Dock, the first bar sits against
    /// the Dock and the next against that one. Bars set to the same end share
    /// the room there, shrinking as far as they can; only when that is not
    /// enough does one go to the other end rather than on top of its
    /// neighbour.
    private func relayout() {
        // Resizing a window under a running slide would make it jump, and the
        // bars are about to move anyway: wait for the slide to finish.
        guard !bars.contains(where: \.isSliding) else {
            needsRelayout = true
            return
        }
        needsRelayout = false
        guard let dock = tracker.geometry else { return }

        var taken: [Settings.Side: CGFloat] = [:]
        var regions: [CGRect] = []
        func place(_ bar: BarController, _ layout: PanelLayout, at side: Settings.Side) {
            bar.apply(layout)
            taken[side, default: 0] += layout.length + PanelLayout.spacing
            regions.append(layout.shownFrame)
        }
        func widths(of bar: BarController) -> [CGFloat] {
            bar.widgets.map { $0.info.widthFactor }
        }

        // First the ends where everything set to be there fits together.
        let shown = shownBars
        var crowded: [BarController] = []
        for side in [Settings.Side.leading, .trailing] {
            let here = shown.filter { self.side(of: $0) == side }
            if let shares = PanelLayout.share(dock: dock, side: side, among: here.map(widths)) {
                for (bar, share) in zip(here, shares) {
                    place(bar, PanelLayout.make(dock: dock, side: side, share: share, taken: taken[side, default: 0]), at: side)
                }
            } else {
                crowded += here
            }
        }

        // Then the bars of an end that is too crowded even so. Each tries
        // what room is left at its own end; if another bar has taken that,
        // the other end; and failing both, stays put with as many tiles as
        // fit.
        for bar in crowded {
            let chosen = side(of: bar)
            let ends = taken[chosen, default: 0] > 0 ? [chosen, chosen.opposite] : [chosen]
            let fitting = ends.lazy.compactMap { side -> (Settings.Side, PanelLayout.Share)? in
                let room = taken[side, default: 0]
                return PanelLayout.share(dock: dock, side: side, among: [widths(of: bar)], taken: room)?.first.map { (side, $0) }
            }.first
            if let (side, share) = fitting {
                place(bar, PanelLayout.make(dock: dock, side: side, share: share, taken: taken[side, default: 0]), at: side)
            } else {
                let room = taken[chosen, default: 0]
                place(bar, PanelLayout.make(dock: dock, side: chosen, widthFactors: widths(of: bar), taken: room), at: chosen)
            }
        }
        tracker.hoverRegions = regions
    }

    // MARK: - Sliding in and out

    private func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        if revealed {
            // Bring the tiles up to date before they slide into view.
            scheduler.isPublishing = true
        }
        slide()
    }

    /// Moves every bar that is not yet where `isRevealed` says it belongs.
    private func slide() {
        let screen = NSScreen.screens.first { $0.frame == tracker.geometry?.screenFrame }
        for bar in shownBars {
            bar.setRevealed(isRevealed, duration: slideDuration, on: screen) { [weak self] in
                self?.slideFinished()
            }
        }
    }

    private func slideFinished() {
        guard !bars.contains(where: \.isSliding) else { return }
        if !isRevealed {
            // With the bars off screen the views stop updating until the next
            // reveal.
            scheduler.isPublishing = false
            slideDuration = DockPreferences.slideDuration
        }
        if needsRelayout {
            relayout()
        }
    }

    /// Hold the bars in place while something that belongs to them is open,
    /// even though the pointer has left the Dock's strip.
    private func updatePinned() {
        tracker.isPinned = isMenuOpen || bars.contains(where: \.hasCard)
    }

    // MARK: - Right-click menu

    private func showMenu(for event: NSEvent, on bar: BarController) {
        guard let view = bar.menuAnchor else { return }
        bars.forEach { $0.closeCard() }
        let menu = buildMenu(for: bar)
        isMenuOpen = true
        updatePinned()
        // Runs its own event loop and returns once the menu closes.
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        isMenuOpen = false
        updatePinned()
    }

    /// The menu for a right-click on `bar`: what is specific to that bar (its
    /// widgets, its position) and what applies to the whole app.
    private func buildMenu(for bar: BarController) -> NSMenu {
        let settings = self.settings
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Bars
        let hiddenBars = settings.hiddenBars
        let shownBarCount = bars.count - hiddenBars.intersection(bars.map(\.group.id)).count
        menu.addItem(.sectionHeader(title: "Bars"))
        for other in bars {
            let group = other.group
            let isShown = !hiddenBars.contains(group.id)
            let item = ActionMenuItem(group.title, checked: isShown) {
                var hidden = settings.hiddenBars
                if isShown {
                    hidden.insert(group.id)
                } else {
                    hidden.remove(group.id)
                }
                settings.hiddenBars = hidden
            }
            item.image = NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil)
            // The bars are the app's only UI, so the last one cannot be removed.
            item.isEnabled = !(isShown && shownBarCount == 1)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Widgets of this bar. A bar with a single widget has nothing to choose.
        let widgets = bar.group.widgets
        if widgets.count > 1 {
            let hidden = settings.hiddenWidgets
            let shownCount = widgets.filter { !hidden.contains($0.info.id) }.count
            menu.addItem(.sectionHeader(title: "\(bar.group.title) Widgets"))
            for widget in widgets {
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
                // An empty bar could not be right-clicked to bring them back.
                item.isEnabled = !(isShown && shownCount == 1)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Position of this bar
        let isBottom = (tracker.geometry?.edge ?? .bottom) == .bottom
        let side = side(of: bar)
        let barID = bar.group.id
        let position = NSMenu()
        position.addItem(ActionMenuItem(isBottom ? "Left of Dock" : "Above Dock", checked: side == .leading) {
            settings.setSide(.leading, ofBar: barID)
        })
        position.addItem(ActionMenuItem(isBottom ? "Right of Dock" : "Below Dock", checked: side == .trailing) {
            settings.setSide(.trailing, ofBar: barID)
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
