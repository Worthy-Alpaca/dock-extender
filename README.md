# Dock Extender

A small native macOS app that adds a bar of live widgets next to the Dock. It
sits beside the Dock, uses the same glass material and icon size, and slides in
and out together with an auto-hiding Dock.

Included widgets: CPU, memory, GPU, network and disk.

- **Click** a tile for details (per-core load, memory breakdown, and so on).
- **Right-click** the bar to switch widgets on or off, move the bar to the other
  end of the Dock, change the update speed, keep the bar visible while the Dock
  is hidden, launch at login, or quit.

Requires macOS 26 or later. Written in Swift (AppKit for the window, SwiftUI
for the widgets); no dependencies.

## Build and run

```bash
./Scripts/build-app.sh
```

```bash
open build/DockExtender.app
```

Only the Swift toolchain is needed (Xcode or the Command Line Tools).

To install it (or update the installed copy after a change), build with
`--install`: this replaces `/Applications/DockExtender.app` and relaunches it.

```bash
./Scripts/build-app.sh --install
```

Turn on *Launch at Login* from the right-click menu to have it start with the
Mac.

During development, `swift run` starts it straight from the package.

## Adding a widget

A widget is one type conforming to `DockWidget`, plus one line in
`WidgetRegistry.makeAll()`. Nothing else needs to change: the panel lays it
out, the scheduler samples it, and it appears in the right-click menu.

```swift
@MainActor
final class UptimeWidget: DockWidget {
    let info = WidgetInfo(id: "uptime", title: "Uptime", symbol: "clock", interval: 60)
    private let model = UptimeModel()        // an @Observable class

    // Background queue: gather numbers. Never touches the UI.
    nonisolated func read() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // Main actor: publish them to the views.
    func apply(_ reading: TimeInterval) {
        model.hours = reading / 3600
    }

    var tile: some View {
        MetricTile(label: "UP", value: "\(Int(model.hours))h") { EmptyView() }
    }

    var detail: some View {
        DetailCard(title: "Uptime", symbol: "clock", headline: "\(Int(model.hours)) h") {
            StatRow(label: "Since boot", value: "\(Int(model.hours)) hours")
        }
    }
}
```

`UI/` has the shared pieces (`MetricTile`, `Sparkline`, `BarGauge`,
`DetailCard`, `StatRow`), and `History` keeps the recent values for a graph.
The existing widgets in `Sources/DockExtender/Widgets/` are short and make good
templates.

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/DockExtender/Core` | Widget protocol, registry, background sampler, helpers |
| `Sources/DockExtender/Widgets` | One file per widget |
| `Sources/DockExtender/UI` | Shared SwiftUI building blocks |
| `Sources/DockExtender/Dock` | Finding the Dock, the panel window, layout, sliding |
| `Sources/DockExtender/App` | App delegate, settings, developer snapshot tool |

## How it follows the Dock

macOS has no public API for the Dock's position or for when an auto-hiding Dock
appears, so:

- Position, width, icon size and orientation come from the `CoreDock` functions
  in ApplicationServices. They are **private API**, looked up at runtime; if a
  future macOS removes them the app falls back to the Dock's preferences and
  places the bar in the screen corner.
- Whether the Dock is showing is inferred from the pointer (it must rest on the
  Dock's screen edge) and from whether the Dock's window is on screen.

Neither needs Accessibility or Screen Recording permission.

## Performance notes

- Readings are taken on a background queue from one shared timer.
- While the bar is hidden its views are not updated at all; readings queue up
  and the graphs catch up in one step as the bar slides in.
- Dock tracking polls at 10 Hz when the pointer is far from the Dock and only
  speeds up while the pointer is on the Dock's edge or the bar is showing.
- Everything pauses while the display sleeps.

## Debugging

- `DockExtender --debug` logs Dock geometry and show/hide decisions to stderr.
- `DockExtender --snapshot out.png` renders every tile and detail view to
  `out.png` after a few samples, captures the live panel, then quits.
