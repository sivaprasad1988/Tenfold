import AppKit

MainActor.assumeIsolated {
    Localization.applyAtLaunch()       // language choice → permission dialogs, formatters
    let app = NSApplication.shared
    let delegate = AppDelegate()   // NSApplication.delegate is weak – kept alive while run() blocks
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
