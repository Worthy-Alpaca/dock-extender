# Dock Extender

A small native macOS app that adds bars of live widgets next to the Dock. They
sit beside the Dock, use the same glass material, are exactly as tall as the
Dock at any Dock size, and slide in and out together with an auto-hiding Dock.

There are two bars, each of which can be switched on and off and placed at
either end of the Dock on its own. Bars at the same end share the room there:
if it is short, wide tiles go down to the width of a Dock icon first, then all
tiles get narrower. Only when even that is not enough does a bar move to the
other end.

- **System**: CPU, memory, GPU, network and disk.
- **Audio**: what is playing (the track, for players that announce it, or
  else the app), where the sound goes and how loud. Its card has a volume
  slider, and previous, play/pause and next buttons for Music and Spotify.

- **Click** a tile for a card with details (per-core load, memory breakdown,
  and so on). Clicking in a card never takes the keyboard away from the app
  you are working in.
- **Right-click** a bar to switch bars or that bar's widgets on or off, move
  the bar to the other end of the Dock, change the update speed, keep the bars
  visible while the Dock is hidden, launch at login, or quit.

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

## Tests

```bash
./Scripts/test.sh
```

The tests cover what is plain logic: how bars are sized and placed, what the
app remembers about the Dock's depth, clicks and drags on controls, the audio
widget's state, and number formatting. What needs a real Dock, a real audio
device or a real mouse is not covered. (The script is `swift test`, plus a
flag the compiler needs when only the Command Line Tools are installed.)

## Releases

`.github/workflows/build.yml` tests and builds every push to `main` and every
pull request. Pushing a version tag also publishes that build as a GitHub
release, with the zipped app attached and the tag's version in the app:

```bash
git tag v1.1.0
```

```bash
git push origin v1.1.0
```

The released app is signed ad hoc and not notarized by Apple, so macOS will
not open a downloaded copy straight away: open it once, then allow it under
System Settings › Privacy & Security.

## Adding a widget

A widget is one type conforming to `DockWidget`, plus one line in a group in
`WidgetRegistry.makeGroups()`. Nothing else needs to change: the group's bar
lays it out, the scheduler samples it, and it appears in the right-click menu.
A new group there gets a bar of its own.

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
A tile can have buttons and sliders of its own: return their frames and
actions from `controls(in:scale:)` and draw them at those frames; the tile
view handles the mouse. The detail card works the same way through
`detailControls(in:)`, which is where the audio widget has its controls.
The existing widgets in `Sources/DockExtender/Widgets/` are short and make good
templates.

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/DockExtender/Core` | Widget protocol, registry, background sampler, helpers |
| `Sources/DockExtender/Widgets` | One file per widget (audio has a second, for the players) |
| `Sources/DockExtender/UI` | Shared SwiftUI building blocks |
| `Sources/DockExtender/Dock` | Finding the Dock, the bars' windows, layout, sliding |
| `Sources/DockExtender/App` | App delegate, settings, developer snapshot tool |
| `Tests/DockExtenderTests` | Tests for the logic that needs no Dock, device or mouse |
| `Scripts` | Building the app bundle, running the tests |
| `.github/workflows` | Test, build and release on GitHub |

## How it follows the Dock

macOS has no public API for the Dock's position or for when an auto-hiding Dock
appears, so:

- Position, width, icon size and orientation come from the `CoreDock` functions
  in ApplicationServices. They are **private API**, looked up at runtime; if a
  future macOS removes them the app falls back to the Dock's preferences and
  places the bars in the screen corner.
- Whether the Dock is showing is inferred from the pointer (it must rest on the
  Dock's screen edge) and from whether the Dock's window is on screen.
- How tall the Dock is cannot be worked out from its size setting: the Dock
  pads bigger icons more, and shrinks its icons when they would not fit the
  screen. So the app measures it. While the Dock is up it asks the window
  server which window a click would land in, at points further and further
  from the screen edge, until the answer is no longer the Dock (`DockProbe`).
  The result is remembered for each Dock size, also between launches. At a
  size it has not seen before the bars start from an estimate and are
  corrected the moment the Dock is next on screen. A Dock that is always
  showing needs none of this: the system reports the space reserved for it.

None of this needs Accessibility or Screen Recording permission.

## What the audio widget can and cannot see

Core Audio knows, for every process, whether it has a live stream to an output
device, and announces every change. The widget listens to that, so it costs
nothing while nothing changes, and it needs no permission. Helper processes
are shown as the app they work for (a browser's audio helper as the browser).

Track titles come from the players themselves: Music and Spotify post a
system-wide notification whenever playback starts, stops or moves to the next
track, with title, artist and album attached. That takes no permission either.
Because the notification only comes on a change, a track that was already
playing when the app started stays unnamed until then; to cover a restart of
the app, the last track is remembered until it must have ended.

A player that is open but silent stays in the bar, paused, so that it can be
started again from its card. The buttons send the player an Apple event, as the
AppleScript `tell application "Music" to playpause` would. macOS asks, the
first time, whether Dock Extender may control that player, and keeps the
answer under System Settings › Privacy & Security › Automation. (A build made
with `build-app.sh` is signed ad hoc, so to macOS every rebuild is a new app
and it asks again.) The media keys would reach every player, but pressing keys
for the user takes the Accessibility permission, which is far more than this
needs.

The card has a volume slider. Dragging it sets the output device's volume
through Core Audio, which takes no permission, and takes the device off mute,
as the volume keys do.

All of the controls are in the card. The tile only shows: there, a stray
click would set them off.

Two things are out of reach for an ordinary app:

- **Silence.** An app that holds a stream open without sending sound down it
  (a call on mute) still counts as playing. Telling the difference takes the
  audio itself, which macOS only hands over with the audio-recording
  permission.
- **Titles from other apps** (a video in a browser, say). macOS keeps its
  "Now Playing" information, which would cover every app, to itself and
  Apple's own apps; there is no permission to ask for. Those apps show up by
  name.

## Performance notes

- Readings are taken on a background queue from one shared timer.
- While the bars are hidden their views are not updated at all; readings queue
  up and the graphs catch up in one step as the bars slide in.
- Dock tracking polls at 10 Hz when the pointer is far from the Dock and only
  speeds up while the pointer is on the Dock's edge or the bars are showing.
- Measuring the Dock takes six window-server queries (a quarter of a
  millisecond), once every two seconds and only while the Dock is up.
- Everything pauses while the display sleeps.

## Debugging

- `DockExtender --debug` logs Dock geometry, Dock measurements and show/hide
  decisions to stderr.
- `DockExtender --snapshot out.png` renders every tile and detail view to
  `out.png` after a few samples, captures the first bar's window, then quits.
