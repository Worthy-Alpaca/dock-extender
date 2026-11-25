import Foundation

/// Follows the mouse over a widget's controls: which button is held down,
/// which slider is being dragged. Shared by the tiles and the detail card, so
/// that a control behaves the same wherever a widget puts it.
///
/// Points are in the coordinates the controls' frames use (origin top left).
@MainActor
struct ControlMouse {
    /// Index of the button the mouse went down on.
    private(set) var pressed: Int?
    /// Index of the slider being dragged.
    private(set) var sliding: Int?

    /// The control at `point`, if there is one.
    static func index(at point: CGPoint, in controls: [TileControl]) -> Int? {
        controls.firstIndex { $0.frame.contains(point) }
    }

    /// The mouse went down. False if no control is there, so the event is the
    /// caller's to deal with.
    mutating func down(at point: CGPoint, in controls: [TileControl]) -> Bool {
        guard let index = Self.index(at: point, in: controls) else { return false }
        switch controls[index].kind {
        case .button:
            pressed = index
        case .slider(let follow):
            sliding = index
            follow(point)
        }
        return true
    }

    /// The mouse moved with the button held.
    func dragged(to point: CGPoint, in controls: [TileControl]) {
        guard let sliding, sliding < controls.count, case .slider(let follow) = controls[sliding].kind else { return }
        follow(point)
    }

    /// The mouse came up. False if it had not gone down on a control.
    mutating func up(at point: CGPoint, in controls: [TileControl]) -> Bool {
        if sliding != nil {
            dragged(to: point, in: controls)
            sliding = nil
            return true
        }
        guard let index = pressed else { return false }
        pressed = nil
        // Like any button: it counts if the mouse comes up where it went down.
        if Self.index(at: point, in: controls) == index, case .button(let action) = controls[index].kind {
            action()
        }
        return true
    }
}
