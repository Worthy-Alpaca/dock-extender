import Foundation

@MainActor
enum WidgetRegistry {
    /// Every widget the app offers, in display order.
    /// Add new widgets here; they show up in the panel and the right-click menu.
    static func makeAll() -> [any DockWidget] {
        [
            CPUWidget(),
            MemoryWidget(),
            GPUWidget(),
            NetworkWidget(),
            DiskWidget(),
        ]
    }
}
