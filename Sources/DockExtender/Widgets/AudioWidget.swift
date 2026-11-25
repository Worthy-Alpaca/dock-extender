import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: - Sampling

/// One app with a live audio stream, or a player that is open but silent.
struct AudioSource: Sendable, Equatable, Identifiable {
    /// The app answerable for the stream. Helper processes (a browser's audio
    /// helper, WebKit's media process) are counted as the app they work for.
    var pid: pid_t
    var name: String
    /// System uptime, in seconds, when it was first seen playing.
    var since: TimeInterval = 0
    /// Nil for the many apps that do not say what they play.
    var track: AudioTrack?
    /// Bundle ID, if this is a player that takes play and skip commands.
    var player: String?
    /// A player with no stream at the moment. It stays listed so that it can
    /// be started again from the widget.
    var isPaused = false

    var id: pid_t { pid }
}

struct AudioState: Sendable, Equatable {
    /// Whatever is playing, longest-running first, then any paused players.
    var sources: [AudioSource] = []
    var playing: [AudioSource] { sources.filter { !$0.isPaused } }
    /// The one to put up front: something playing that names its track, else
    /// anything playing, else a paused player.
    var main: AudioSource? {
        let playing = playing
        return playing.first { $0.track != nil } ?? playing.first ?? sources.first
    }
    /// Name of the output device sound goes to by default.
    var output = ""
    /// 0...1, or nil for a device without a volume control (many displays).
    var volume: Double?
    var isMuted = false
}

struct AudioReading: Sendable {
    var state = AudioState()
    /// System uptime when the reading was taken; `AudioSource.since` counts
    /// against this.
    var time: TimeInterval = 0
}

/// Follows which processes have a live audio stream to an output device.
///
/// Core Audio keeps an object for every process that talks to it and knows
/// whether that process is running output right now. It also announces every
/// change, so nothing here polls the processes: listeners note which ones
/// changed and the next `read()` asks about only those. (Asking about all of
/// them, some forty on a typical Mac, takes 5 ms; a `read()` with nothing to
/// do takes microseconds.)
///
/// A live stream is not the same as sound. An app can hold a stream open and
/// send silence down it (a call on mute, a paused game). Telling the two apart
/// takes the audio itself, which macOS only hands to apps the user has allowed
/// to record system audio, so this widget does not try.
///
/// Reading happens on the sampling queue only.
final class AudioSampler: @unchecked Sendable {
    private struct Process {
        var owner: pid_t
        var isPlaying = false
    }

    /// An app that is playing.
    private struct Player {
        var name: String
        var bundleID: String?
        var since: TimeInterval
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Seconds between looks at the output device regardless. Changes to its
    /// volume are announced as well; this is for the device that forgets to.
    private static let outputInterval: TimeInterval = 5
    /// Seconds between looks at every process regardless, in case an
    /// announcement went missing.
    private static let sweepInterval: TimeInterval = 60

    // Notes left by the listeners, which run on their own queue.
    private let lock = NSLock()
    private var changedProcesses: Set<AudioObjectID> = []
    private var processListChanged = true
    private var outputChanged = true
    private let events = DispatchQueue(label: "DockExtender.audio-events", qos: .utility)
    private let commands = DispatchQueue(label: "DockExtender.audio-commands", qos: .userInitiated)

    private var isListening = false
    private var processes: [AudioObjectID: Process] = [:]
    private var players: [pid_t: Player] = [:]
    private let remotes = PlayerWatcher()
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var watchedDevices: Set<AudioObjectID> = []
    private var state = AudioState()
    private var lastOutputRead: TimeInterval = 0
    private var lastSweep: TimeInterval = 0

    func read() -> AudioReading {
        let now = ProcessInfo.processInfo.systemUptime
        if !isListening {
            isListening = true
            lastSweep = now
            listen(to: Self.system, kAudioHardwarePropertyProcessObjectList) { $0.processListChanged = true }
            listen(to: Self.system, kAudioHardwarePropertyDefaultOutputDevice) { $0.outputChanged = true }
        }

        lock.lock()
        var changed = changedProcesses
        var listChanged = processListChanged
        var outputChanged = self.outputChanged
        changedProcesses = []
        processListChanged = false
        self.outputChanged = false
        lock.unlock()

        if now - lastSweep >= Self.sweepInterval {
            lastSweep = now
            listChanged = true
            changed.formUnion(processes.keys)
        }
        if now - lastOutputRead >= Self.outputInterval {
            outputChanged = true
        }

        if listChanged {
            updateProcessList(changed: &changed)
        }
        if listChanged || !changed.isEmpty {
            for object in changed {
                updatePlaying(object)
            }
            updatePlayers(at: now)
        }
        // Tracks change without the stream changing, so the players are
        // asked every time; it is a short list behind a lock.
        let remotes = remotes.players()
        var sources = players
            .map { pid, player in
                let remote = remotes.first { $0.bundleID == player.bundleID }
                return AudioSource(
                    pid: pid,
                    name: player.name,
                    since: player.since,
                    track: remote?.track,
                    player: remote?.bundleID
                )
            }
            .sorted { ($0.since, $0.pid) < ($1.since, $1.pid) }
        for remote in remotes where !sources.contains(where: { $0.player == remote.bundleID }) {
            sources.append(AudioSource(
                pid: remote.pid,
                name: remote.name,
                track: remote.track,
                player: remote.bundleID,
                isPaused: true
            ))
        }
        state.sources = sources
        if outputChanged {
            lastOutputRead = now
            updateOutput()
        }
        return AudioReading(state: state, time: now)
    }

    // MARK: Processes

    /// Brings `processes` in line with Core Audio's list, and starts
    /// listening to the ones that are new.
    private func updateProcessList(changed: inout Set<AudioObjectID>) {
        let current = Set(Self.objects(Self.system, kAudioHardwarePropertyProcessObjectList))
        for object in processes.keys where !current.contains(object) {
            processes[object] = nil
        }
        for object in current where processes[object] == nil {
            guard let pid: pid_t = Self.value(object, kAudioProcessPropertyPID) else { continue }
            processes[object] = Process(owner: Self.owner(of: pid))
            // Any change to the process: whether it runs is announced under
            // more than one name.
            listen(to: object, kAudioObjectPropertySelectorWildcard) { $0.changedProcesses.insert(object) }
            changed.insert(object)
        }
    }

    private func updatePlaying(_ object: AudioObjectID) {
        guard processes[object] != nil else { return }
        guard let running: UInt32 = Self.value(object, kAudioProcessPropertyIsRunningOutput) else {
            // The process has gone since.
            processes[object] = nil
            return
        }
        processes[object]?.isPlaying = running != 0
    }

    private func updatePlayers(at now: TimeInterval) {
        let playing = Set(processes.values.lazy.filter(\.isPlaying).map(\.owner))
        players = players.filter { playing.contains($0.key) }
        for owner in playing where players[owner] == nil {
            let app = NSRunningApplication(processIdentifier: owner)
            players[owner] = Player(
                name: Self.name(of: owner, app: app),
                bundleID: app?.bundleIdentifier,
                since: now
            )
        }
    }

    /// The app a process works for: Safari for WebKit's media process, the
    /// browser for its audio helper, the terminal for a command-line player.
    private static func owner(of pid: pid_t) -> pid_t {
        guard let responsible = responsiblePID?(pid), responsible > 0 else { return pid }
        return responsible
    }

    /// Private, but the only way to ask; without it helpers appear under
    /// their own names.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func name(of pid: pid_t, app: NSRunningApplication?) -> String {
        if let name = app?.localizedName, !name.isEmpty {
            return name
        }
        // Not an app: a system service or a command-line tool.
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "Process \(pid)" }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name == "systemsoundserverd" ? "System Sounds" : name
    }

    // MARK: Output device

    private func updateOutput() {
        let current: AudioObjectID = Self.value(Self.system, kAudioHardwarePropertyDefaultOutputDevice)
            ?? AudioObjectID(kAudioObjectUnknown)
        if current != device || state.output.isEmpty {
            device = current
            state.output = Self.string(current, kAudioObjectPropertyName) ?? ""
            if watchedDevices.insert(current).inserted {
                let scope = kAudioDevicePropertyScopeOutput
                listen(to: current, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) { $0.outputChanged = true }
                listen(to: current, kAudioDevicePropertyMute, scope) { $0.outputChanged = true }
            }
        }
        let volume: Float32? = Self.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        let mute: UInt32? = Self.value(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        state.volume = volume.map { Double(min(max($0, 0), 1)) }
        state.isMuted = mute == 1
    }

    /// Sets the volume of the output device and takes it off mute, as the
    /// volume keys do. Returns at once; the device is told on another queue.
    func setVolume(_ volume: Double) {
        commands.async { [self] in
            guard let device: AudioObjectID = Self.value(Self.system, kAudioHardwarePropertyDefaultOutputDevice) else { return }
            let scope = kAudioDevicePropertyScopeOutput
            Self.set(Float32(volume), on: device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
            if let muted: UInt32 = Self.value(device, kAudioDevicePropertyMute, scope), muted != 0 {
                Self.set(UInt32(0), on: device, kAudioDevicePropertyMute, scope)
            }
            // Have the next reading look at the device, announcement or not.
            lock.lock()
            outputChanged = true
            lock.unlock()
        }
    }

    // MARK: Core Audio plumbing

    /// Has `note` run, under the lock, whenever the property changes.
    private func listen(
        to object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        note: @escaping @Sendable (AudioSampler) -> Void
    ) {
        var address = Self.address(selector, scope)
        if selector == kAudioObjectPropertySelectorWildcard {
            address.mScope = kAudioObjectPropertyScopeWildcard
            address.mElement = kAudioObjectPropertyElementWildcard
        }
        _ = AudioObjectAddPropertyListenerBlock(object, &address, events) { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            note(self)
            self.lock.unlock()
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a plain value (a number, an object ID). Nil when the object has
    /// no such property or no longer exists.
    private static func value<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!) == noErr,
                  size == UInt32(MemoryLayout<T>.size)
            else { return nil }
            return buffer[0]
        }
    }

    private static func set<T: BitwiseCopyable>(
        _ value: T,
        on object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) {
        var address = address(selector, scope)
        var value = value
        _ = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

// MARK: - Widget

@MainActor
@Observable
final class AudioModel {
    private(set) var state = AudioState()
    /// Uptime of the latest reading, for "playing for ...".
    private(set) var now: TimeInterval = 0
    /// Name of a player macOS would not let this app control.
    private(set) var refusedPlayer: String?
    /// A volume just set by dragging the slider, shown at once rather than
    /// when the device reports it back a moment later.
    private var chosenVolume: (value: Double, until: TimeInterval)?
    /// Where the controls are in the detail card, as SwiftUI laid them out.
    @ObservationIgnored var sliderFrame = CGRect.null
    @ObservationIgnored var buttonFrames: [PlayerCommand: CGRect] = [:]
    /// Passes a volume on to the output device.
    var setOutputVolume: ((Double) -> Void)?

    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]

    func update(_ reading: AudioReading) {
        // Most readings repeat the one before; leave the views alone then.
        if reading.state != state {
            state = reading.state
            let playing = Set(state.sources.map(\.pid))
            icons = icons.filter { playing.contains($0.key) }
        }
        if !state.playing.isEmpty {
            now = reading.time
        }
        if let chosen = chosenVolume, reading.time >= chosen.until {
            chosenVolume = nil
        }
    }

    /// 0...1, or nil for an output without a volume control.
    var volume: Double? {
        state.volume == nil ? nil : chosenVolume?.value ?? state.volume
    }

    var isMuted: Bool {
        chosenVolume == nil && state.isMuted
    }

    func setVolume(_ volume: Double) {
        guard state.volume != nil else { return }
        let volume = min(max(volume, 0), 1)
        chosenVolume = (volume, ProcessInfo.processInfo.systemUptime + 1.5)
        setOutputVolume?(volume)
    }

    /// The player the buttons act on: the one up front, if it takes commands.
    var remote: AudioSource? {
        guard let source = state.main, source.player != nil else { return nil }
        return source
    }

    func send(_ command: PlayerCommand) {
        guard let source = remote, let player = source.player else { return }
        PlayerRemote.send(command, to: player, pid: source.pid) { outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch outcome {
                    case .sent: self.refusedPlayer = nil
                    case .notAllowed: self.refusedPlayer = source.name
                    case .failed: break
                    }
                }
            }
        }
    }

    /// The app's icon, or nil for something that is not an app.
    func icon(for source: AudioSource) -> NSImage? {
        if let icon = icons[source.pid] {
            return icon
        }
        let icon = NSRunningApplication(processIdentifier: source.pid)?.icon
        icons[source.pid] = icon
        return icon
    }

    var volumeText: String {
        if isMuted {
            return "Mute"
        }
        return volume.map(Format.percent) ?? "–"
    }

    var tint: Color {
        isMuted ? .gray : .pink
    }
}

@MainActor
final class AudioWidget: DockWidget {
    /// Wide enough for a track title, where the Dock leaves room for it.
    let info = WidgetInfo(id: "audio", title: "Audio", symbol: "speaker.wave.2", widthFactor: 3.2)

    private nonisolated let sampler = AudioSampler()
    private let model = AudioModel()

    init() {
        model.setOutputVolume = { [sampler] volume in sampler.setVolume(volume) }
    }

    nonisolated func read() -> AudioReading {
        sampler.read()
    }

    func apply(_ reading: AudioReading) {
        model.update(reading)
    }

    var tile: some View {
        AudioTile(model: model)
    }

    var detail: some View {
        AudioDetail(model: model)
    }

    /// The volume slider and the play and skip buttons. They live in the
    /// card rather than the tile, where a stray click would set them off.
    func detailControls(in size: CGSize) -> [TileControl] {
        let model = self.model
        var controls: [TileControl] = []

        let slider = model.sliderFrame
        if model.volume != nil, !slider.isNull, slider.width > VolumeSlider.knob {
            // The knob's centre travels from half a knob in at one end to
            // half a knob in at the other.
            let start = slider.minX + VolumeSlider.knob / 2
            let travel = slider.width - VolumeSlider.knob
            // Taller than the slider, so it need not be hit exactly.
            controls.append(TileControl(frame: slider.insetBy(dx: 0, dy: -6), kind: .slider { point in
                model.setVolume(Double((point.x - start) / travel))
            }))
        }
        if model.remote != nil {
            for command in PlayerCommand.allCases {
                guard let frame = model.buttonFrames[command] else { continue }
                controls.append(TileControl(frame: frame, kind: .button { model.send(command) }))
            }
        }
        return controls
    }
}

// MARK: - Views

/// An app's icon, or a stand-in for something that has none.
private struct SourceIcon: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size * 0.8, height: size * 0.8)
                .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                .frame(width: size, height: size)
        }
    }
}

/// The volume as a slider: a filled track with a knob at the end of it. It
/// only draws; dragging is handled by the card (see `detailControls`).
private struct VolumeSlider: View {
    static let knob: CGFloat = 14

    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let position = (geometry.size.width - Self.knob) * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(tint)
                    .frame(width: position + Self.knob / 2, height: 5)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: position)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.knob)
    }
}

/// Wide where the bar runs along the screen edge and there is room for a
/// title; the usual square tile in a vertical Dock.
private struct AudioTile: View {
    let model: AudioModel

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height * 1.8 {
                WideAudioTile(model: model)
            } else {
                SquareAudioTile(model: model)
            }
        }
    }
}

/// App icon, then what is playing, with the volume underneath.
private struct WideAudioTile: View {
    let model: AudioModel
    @Environment(\.tileScale) private var scale

    var body: some View {
        let state = model.state
        let main = state.main
        let isPaused = main?.isPaused ?? false
        let others = state.playing.count - (main.map { !$0.isPaused } == true ? 1 : 0)

        HStack(spacing: 6 * scale) {
            icon
                .opacity(isPaused ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1.5 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 3 * scale) {
                    Text(title)
                        .font(.system(size: 10.5 * scale, weight: .semibold))
                        .foregroundStyle(main == nil || isPaused ? HierarchicalShapeStyle.secondary : .primary)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if others > 0 {
                        Text("+\(others)")
                            .font(.system(size: 8.5 * scale, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Text(subtitle)
                    .font(.system(size: 8.5 * scale, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let volume = model.volume {
                    HStack(spacing: 4 * scale) {
                        BarGauge(fraction: model.isMuted ? 0 : volume, tint: model.tint)
                            .frame(height: 3.5 * scale)
                        Text(model.volumeText)
                            .font(.system(size: 8 * scale, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            .lineLimit(1)
        }
        .tilePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var icon: some View {
        let size = 36 * scale
        if let source = model.state.main {
            SourceIcon(icon: model.icon(for: source), size: size)
        } else {
            // App icons leave a margin inside their frame; match it.
            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.zzz.fill")
                .font(.system(size: 14 * scale))
                .foregroundStyle(.tertiary)
                .frame(width: size * 0.82, height: size * 0.82)
                .graphWell()
                .frame(width: size, height: size)
        }
    }

    private var title: String {
        guard let source = model.state.main else { return "Nothing playing" }
        return source.track?.title ?? source.name
    }

    /// The artist when the track is known, otherwise where the sound goes.
    private var subtitle: String {
        guard let source = model.state.main else { return model.state.output }
        if let track = source.track {
            let artist = track.artist.isEmpty ? source.name : track.artist
            return source.isPaused ? "Paused · \(artist)" : artist
        }
        return source.isPaused ? "Not playing" : model.state.output
    }
}

/// Volume on top, icons of whatever is playing underneath.
private struct SquareAudioTile: View {
    let model: AudioModel
    @Environment(\.tileScale) private var scale

    var body: some View {
        MetricTile(label: "VOL", value: model.volumeText) {
            playing
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .graphWell()
        }
    }

    /// As many icons as fit, then a count of the rest.
    @ViewBuilder private var playing: some View {
        let sources = model.state.playing
        if sources.isEmpty {
            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.zzz.fill")
                .font(.system(size: 13 * scale))
                .foregroundStyle(.tertiary)
        } else {
            let shown = sources.count > 3 ? 2 : sources.count
            let size: CGFloat = shown == 1 ? 24 : shown == 2 ? 19 : 15
            HStack(spacing: 1 * scale) {
                ForEach(sources.prefix(shown)) { source in
                    SourceIcon(icon: model.icon(for: source), size: size * scale)
                }
                if sources.count > shown {
                    Text("+\(sources.count - shown)")
                        .font(.system(size: 8.5 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }
}

/// Coordinate space of the audio card, for telling the card's view where the
/// controls are.
private let audioCardSpace = "audio-card"

/// Previous, play/pause and next. They only draw; clicks are handled by the
/// card (see `detailControls`).
private struct TransportButtons: View {
    let model: AudioModel
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 14) {
            ForEach(PlayerCommand.allCases, id: \.self) { command in
                Image(systemName: symbol(for: command))
                    .font(.system(size: command == .playPause ? 17 : 13, weight: .semibold))
                    .frame(width: 40, height: 28)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(audioCardSpace)) } action: { frame in
                        model.buttonFrames[command] = frame
                    }
            }
        }
        .foregroundStyle(.primary.opacity(0.85))
        .frame(maxWidth: .infinity)
    }

    private func symbol(for command: PlayerCommand) -> String {
        switch command {
        case .previous: return "backward.fill"
        case .playPause: return isPaused ? "play.fill" : "pause.fill"
        case .next: return "forward.fill"
        }
    }
}

private struct AudioDetail: View {
    let model: AudioModel

    var body: some View {
        let state = model.state
        DetailCard(title: "Audio", symbol: "speaker.wave.2", headline: model.volumeText) {
            if let volume = model.volume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                    VolumeSlider(fraction: model.isMuted ? 0 : volume, tint: model.tint)
                        // The card's view handles the mouse; tell it where.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(audioCardSpace)) } action: { frame in
                            model.sliderFrame = frame
                        }
                    Image(systemName: "speaker.wave.3.fill")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Divider()
            if state.sources.isEmpty {
                Text("Nothing is playing")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(state.sources) { source in
                HStack(alignment: .top, spacing: 6) {
                    SourceIcon(icon: model.icon(for: source), size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.track?.title ?? source.name)
                            .lineLimit(1)
                        if let track = source.track {
                            Text(byline(of: track, playedBy: source))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(source.isPaused ? "Paused" : Format.duration(model.now - source.since))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .opacity(source.isPaused ? 0.7 : 1)
                if source.id == model.remote?.id {
                    TransportButtons(model: model, isPaused: source.isPaused)
                }
            }
            if let player = model.refusedPlayer {
                Text("macOS is not letting Dock Extender control \(player). Allow it under System Settings › Privacy & Security › Automation.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            StatRow(label: "Output", value: state.output.isEmpty ? "None" : state.output)
        }
        .coordinateSpace(name: audioCardSpace)
    }

    /// "Artist — Album", or the app's name for a track that has neither.
    private func byline(of track: AudioTrack, playedBy source: AudioSource) -> String {
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? source.name : parts.joined(separator: " — ")
    }
}
