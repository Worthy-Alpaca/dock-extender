import CoreGraphics
import Testing
@testable import DockExtender

/// Clicks and drags on the buttons and sliders a widget puts in its views.
@MainActor
struct ControlMouseTests {
    /// Collects what the controls were told.
    private final class Log {
        var clicks = 0
        var slid: [CGFloat] = []
    }

    private func controls(_ log: Log) -> [TileControl] {
        [
            TileControl(frame: CGRect(x: 0, y: 0, width: 20, height: 20), kind: .button { log.clicks += 1 }),
            TileControl(frame: CGRect(x: 30, y: 0, width: 100, height: 20), kind: .slider { log.slid.append($0.x) }),
        ]
    }

    @Test func aPressOutsideAnyControlIsLeftToTheCaller() {
        let log = Log()
        var mouse = ControlMouse()
        let tookDown = mouse.down(at: CGPoint(x: 200, y: 5), in: controls(log))
        let tookUp = mouse.up(at: CGPoint(x: 200, y: 5), in: controls(log))
        #expect(!tookDown)
        #expect(!tookUp)
        #expect(log.clicks == 0)
    }

    @Test func aButtonClicksWhenTheMouseComesUpOnIt() {
        let log = Log()
        var mouse = ControlMouse()
        let tookDown = mouse.down(at: CGPoint(x: 5, y: 5), in: controls(log))
        #expect(tookDown)
        #expect(mouse.pressed == 0)
        #expect(log.clicks == 0)

        let tookUp = mouse.up(at: CGPoint(x: 6, y: 6), in: controls(log))
        #expect(tookUp)
        #expect(log.clicks == 1)
        #expect(mouse.pressed == nil)
    }

    @Test func aButtonDoesNotClickWhenTheMouseComesUpElsewhere() {
        let log = Log()
        var mouse = ControlMouse()
        _ = mouse.down(at: CGPoint(x: 5, y: 5), in: controls(log))
        let tookUp = mouse.up(at: CGPoint(x: 50, y: 50), in: controls(log))
        #expect(tookUp)
        #expect(log.clicks == 0)
    }

    @Test func aSliderFollowsTheMouseUntilItComesUp() {
        let log = Log()
        var mouse = ControlMouse()
        let tookDown = mouse.down(at: CGPoint(x: 40, y: 10), in: controls(log))
        #expect(tookDown)
        #expect(log.slid == [40])

        // It keeps following outside its own frame.
        mouse.dragged(to: CGPoint(x: 90, y: 300), in: controls(log))
        #expect(log.slid == [40, 90])

        let tookUp = mouse.up(at: CGPoint(x: 500, y: -40), in: controls(log))
        #expect(tookUp)
        #expect(log.slid == [40, 90, 500])

        // And stops once the mouse is up.
        mouse.dragged(to: CGPoint(x: 60, y: 10), in: controls(log))
        #expect(log.slid.count == 3)
        #expect(log.clicks == 0)
    }
}
