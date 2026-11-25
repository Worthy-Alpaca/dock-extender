import Foundation

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings {
    /// Which end of the Dock a bar attaches to. Trailing is the Trash end.
    enum Side: String {
        case leading, trailing

        var opposite: Side { self == .leading ? .trailing : .leading }
    }

    /// Called after any preference changes.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    /// The end of the Dock chosen for a bar, or nil while it is left to the
    /// default.
    func side(ofBar id: String) -> Side? {
        Side(rawValue: defaults.string(forKey: sideKey(id)) ?? "")
    }

    func setSide(_ side: Side, ofBar id: String) {
        defaults.set(side.rawValue, forKey: sideKey(id))
        onChange?()
    }

    /// The system bar keeps the key it had when it was the only bar.
    private func sideKey(_ bar: String) -> String {
        bar == "system" ? "side" : "side.\(bar)"
    }

    /// IDs of the bars the user switched off.
    var hiddenBars: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenBars") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "hiddenBars"); onChange?() }
    }

    /// IDs of widgets the user switched off. Storing the hidden set (rather than
    /// the shown set) means newly added widgets appear by default.
    var hiddenWidgets: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenWidgets") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "hiddenWidgets"); onChange?() }
    }

    /// Multiplier applied to every widget's refresh interval (1 = as designed).
    var intervalScale: Double {
        get {
            let value = defaults.double(forKey: "intervalScale")
            return value > 0 ? value : 1
        }
        set { defaults.set(newValue, forKey: "intervalScale"); onChange?() }
    }

    /// With an auto-hiding Dock: keep the bars on screen instead of sliding
    /// away with the Dock.
    var keepVisible: Bool {
        get { defaults.bool(forKey: "keepVisible") }
        set { defaults.set(newValue, forKey: "keepVisible"); onChange?() }
    }
}
