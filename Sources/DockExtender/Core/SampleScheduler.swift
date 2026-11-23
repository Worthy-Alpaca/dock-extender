import Foundation

/// Drives every widget's `read()` from one background timer.
///
/// A single timer (rather than one per widget) keeps wake-ups to a minimum and
/// makes all tiles update in the same frame.
@MainActor
final class SampleScheduler {
    private let queue = DispatchQueue(label: "dock-extender.sampling", qos: .utility)
    private let gate = UpdateGate()
    private var timer: DispatchSourceTimer?
    private var schedule: (widgets: [any DockWidget], intervalScale: Double)?

    /// Whether readings reach the views. Turn off while the panel is off
    /// screen: sampling continues so the graphs have no gaps, but the views
    /// are left alone, and catch up in one step when this turns back on.
    var isPublishing: Bool {
        get { gate.isOpen }
        set { gate.isOpen = newValue }
    }

    /// Starts sampling `widgets`, replacing any previous schedule.
    func run(_ widgets: [any DockWidget], intervalScale: Double) {
        schedule = (widgets, intervalScale)
        timer?.cancel()
        timer = nil

        let entries = widgets.map {
            Runner.Entry(widget: $0, interval: max(0.25, $0.info.interval * intervalScale))
        }
        guard let tick = entries.map(\.interval).min() else { return }
        timer = Self.makeTimer(on: queue, tick: tick, runner: Runner(entries: entries, gate: gate))
    }

    /// Stops sampling entirely, e.g. while the display sleeps.
    func pause() {
        timer?.cancel()
        timer = nil
    }

    func resume() {
        guard timer == nil, let schedule else { return }
        run(schedule.widgets, intervalScale: schedule.intervalScale)
    }

    /// Nonisolated on purpose: a closure created inside a main-actor method is
    /// itself bound to the main actor, and this handler must run on `queue`.
    private nonisolated static func makeTimer(
        on queue: DispatchQueue,
        tick: TimeInterval,
        runner: Runner
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: tick, leeway: .milliseconds(Int(tick * 100)))
        timer.setEventHandler { runner.fire() }
        timer.resume()
        return timer
    }
}

/// Holds back view updates while nobody can see them.
///
/// Updating SwiftUI views costs far more than taking the readings, so while
/// the panel is hidden the updates queue up here instead.
@MainActor
final class UpdateGate {
    /// Enough for every widget to refill a full graph.
    private static let limit = 600

    private var pending: [() -> Void] = []

    var isOpen = false {
        didSet {
            guard isOpen, !pending.isEmpty else { return }
            let updates = pending
            pending.removeAll(keepingCapacity: true)
            updates.forEach { $0() }
        }
    }

    func submit(_ update: @escaping () -> Void) {
        if isOpen {
            update()
        } else {
            pending.append(update)
            if pending.count > Self.limit {
                pending.removeFirst(pending.count - Self.limit)
            }
        }
    }
}

/// Timer-side state. Only ever touched on the sampling queue.
private final class Runner: @unchecked Sendable {
    struct Entry: Sendable {
        let widget: any DockWidget
        let interval: TimeInterval
        var due: UInt64 = 0
    }

    private var entries: [Entry]
    private let gate: UpdateGate

    init(entries: [Entry], gate: UpdateGate) {
        self.entries = entries
        self.gate = gate
    }

    func fire() {
        let now = DispatchTime.now().uptimeNanoseconds
        for index in entries.indices where entries[index].due <= now {
            entries[index].widget.refresh(through: gate)
            // Aim slightly early so timer jitter never makes a widget skip a tick.
            entries[index].due = now + UInt64(entries[index].interval * 0.9 * 1_000_000_000)
        }
    }
}
