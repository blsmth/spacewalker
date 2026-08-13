import AppKit

// Menu-bar–only agent app: no Dock icon, no main window. (LSUIElement in the bundle Info.plist;
// .accessory covers the same for a bare `swift run`.)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
