import AppKit
import SwiftUI

/// Owns the concrete Settings window used by the accessory app. A dedicated
/// controller is more reliable than asking AppKit to materialize a SwiftUI
/// Settings scene from a background application's menu action.
final class HaloSettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "Halo Settings"
            settingsWindow.titleVisibility = .hidden
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.minSize = NSSize(width: 900, height: 620)
            settingsWindow.contentView = NSHostingView(rootView: SettingsRootView())
            settingsWindow.delegate = self
            window = settingsWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the controller alive so opening Settings again reuses the same
        // window and preserves the selected tab for this app session.
    }
}
