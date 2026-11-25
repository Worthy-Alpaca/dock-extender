import AppKit

/// Bridge to the Dock's own geometry calls in ApplicationServices.
///
/// These are private API: there is no public way to ask where the Dock is or
/// how wide it currently is. They answer from in-process state (well under a
/// microsecond per call) and need no permissions. Every symbol is looked up at
/// runtime, so if a future macOS drops one the accessor returns nil and
/// `DockGeometry` falls back to preferences and screen insets.
@MainActor
enum CoreDock {
    private typealias RectFunction = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
    private typealias OrientationFunction = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    private typealias FlagFunction = @convention(c) () -> UInt8
    private typealias FloatFunction = @convention(c) () -> Float

    private static let handle = dlopen(nil, RTLD_LAZY)
    private static let getRect: RectFunction? = symbol("CoreDockGetRect")
    private static let getOrientation: OrientationFunction? = symbol("CoreDockGetOrientationAndPinning")
    private static let getAutoHide: FlagFunction? = symbol("CoreDockGetAutoHideEnabled")
    private static let getTileSize: FloatFunction? = symbol("CoreDockGetTileSize")
    private static let getMagnification: FlagFunction? = symbol("CoreDockIsMagnificationEnabled")

    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The Dock bar in global display coordinates (origin at the top-left of
    /// the primary display). While an auto-hiding Dock is tucked away the rect
    /// collapses onto the screen edge but still reports the bar's extent along it.
    static var rect: CGRect? {
        guard let getRect else { return nil }
        var rect = CGRect.zero
        getRect(&rect)
        return rect == .zero ? nil : rect
    }

    static var edge: DockEdge? {
        guard let getOrientation else { return nil }
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        getOrientation(&orientation, &pinning)
        switch orientation {
        case 2: return .bottom
        case 3: return .left
        case 4: return .right
        default: return nil
        }
    }

    static var autohide: Bool? {
        getAutoHide.map { $0() != 0 }
    }

    /// Whether icons grow under the pointer.
    static var magnifies: Bool {
        getMagnification.map { $0() != 0 } ?? false
    }

    /// Icon size the Dock is set to, in points. CoreDock reports the slider
    /// position (0...1), which maps linearly onto the 16...128 pt range of the
    /// `tilesize` preference. A full Dock draws its icons smaller than this.
    static var tileSize: CGFloat? {
        guard let getTileSize else { return nil }
        let position = CGFloat(getTileSize())
        guard position.isFinite, (0...1).contains(position) else { return nil }
        return (16 + position * 112).rounded()
    }
}

/// The Dock's preference domain, for values CoreDock does not expose.
@MainActor
enum DockPreferences {
    private static let domain = "com.apple.dock" as CFString

    static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static var edge: DockEdge? {
        switch value("orientation") as? String {
        case "left": return .left
        case "right": return .right
        case "bottom": return .bottom
        default: return nil
        }
    }

    /// How long the Dock takes to slide in or out. The preference is a
    /// multiplier (0.5 when unset) on a half-second base, which matches the
    /// quarter second measured on a stock setup.
    static var slideDuration: TimeInterval {
        let modifier = (value("autohide-time-modifier") as? NSNumber)?.doubleValue ?? 0.5
        return min(max(modifier, 0), 3) * 0.5
    }
}
