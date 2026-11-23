import Foundation

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings {
    /// Which end of the Dock the panel attaches to. Trailing is the Trash end.
    enum Side: String {
        case leading, trailing
    }

    /// Called after any preference changes.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    var side: Side {
        get { Side(rawValue: defaults.string(forKey: "side") ?? "") ?? .trailing }
        set { defaults.set(newValue.rawValue, forKey: "side"); onChange?() }
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

    /// With an auto-hiding Dock: keep the panel on screen instead of sliding
    /// away with the Dock.
    var keepVisible: Bool {
        get { defaults.bool(forKey: "keepVisible") }
        set { defaults.set(newValue, forKey: "keepVisible"); onChange?() }
    }
}
