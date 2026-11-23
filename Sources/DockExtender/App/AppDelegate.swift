import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DockPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }

        let widgets = WidgetRegistry.makeAll()
        let controller = DockPanelController(settings: Settings(), widgets: widgets)
        controller.start()
        self.controller = controller

        // Developer aid: `DockExtender --snapshot out.png` renders every tile and
        // detail view to an image after a few samples, captures the live panel
        // (and a popover, when the panel is showing), then quits.
        if let path = Self.argument(after: "--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                MainActor.assumeIsolated {
                    controller.writeSnapshots(to: URL(fileURLWithPath: path)) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1
    }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
