import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory apps have no Dock icon and no menu bar; the panel is the whole UI.
app.setActivationPolicy(.accessory)
app.run()
