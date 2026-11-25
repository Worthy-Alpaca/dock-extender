import Foundation

/// Widgets that share one bar next to the Dock. Each bar can be switched on
/// and off and moved to either end of the Dock on its own.
struct WidgetGroup {
    /// Stable identifier, used to remember the bar's settings.
    let id: String
    /// Name shown in the right-click menu.
    let title: String
    /// SF Symbol shown next to the title.
    let symbol: String
    let widgets: [any DockWidget]
}

@MainActor
enum WidgetRegistry {
    /// Every widget the app offers, grouped into bars, in display order.
    /// Add a widget to a group and it shows up in that bar and its menu; add
    /// a group and it gets a bar of its own.
    static func makeGroups() -> [WidgetGroup] {
        [
            WidgetGroup(id: "system", title: "System", symbol: "cpu", widgets: [
                CPUWidget(),
                MemoryWidget(),
                GPUWidget(),
                NetworkWidget(),
                DiskWidget(),
            ]),
            WidgetGroup(id: "audio", title: "Audio", symbol: "speaker.wave.2", widgets: [
                AudioWidget(),
            ]),
        ]
    }
}
