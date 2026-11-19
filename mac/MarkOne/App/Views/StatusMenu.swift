// The menu bar icon's right-click menu: Settings, the firmware window,
// updates, help and Quit. A left click still opens the panel. SwiftUI's
// MenuBarExtra has no right-click menu, so this watches for right clicks
// (and Control-clicks) on the icon's window and shows its own menu there.

import AppKit
import SwiftUI

@MainActor
enum StatusMenu {
    /// Starts watching for right clicks. `openWindow` and `openSettings`
    /// come from a view that's always there: the menu bar icon.
    static func start(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let rightClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard rightClick, let window = event.window,
                  String(describing: type(of: window)).contains("StatusBarWindow"),
                  let button = ScreenshotRequests.statusButton, button.window === window
            else { return event }
            MainActor.assumeIsolated { show(below: button, openWindow: openWindow, openSettings: openSettings) }
            return nil
        }
    }

    private static var monitor: Any?

    private static func show(below button: NSButton, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Item("Settings…", key: ",") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        })
        menu.addItem(Item("Camera Firmware…") { openWindow.firmware() })
        if Updater.enabled {
            menu.addItem(Item("Check for Updates…", enabled: Updater.shared.canCheck) { Updater.shared.check() })
        }
        menu.addItem(.separator())
        menu.addItem(Item("Mark One Help") {
            NSWorkspace.shared.open(URL(string: "https://superhighfives.com/mark-one/help")!)
        })
        menu.addItem(.separator())
        // Quitting mid-update can interrupt it; the panel's Quit is
        // disabled then too.
        menu.addItem(Item("Quit Mark One", key: "q", enabled: !Pipeline.shared.updating) { NSApp.terminate(nil) })
        button.highlight(true)
        // Just below the menu bar, like the system's own menus: the icon's
        // window is the menu bar's height, and with no view the point is in
        // screen coordinates.
        let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: (button.window?.frame.minY ?? frame.minY) - 4), in: nil)
        button.highlight(false)
    }

    /// A menu item that runs a closure.
    private final class Item: NSMenuItem {
        private let run: () -> Void

        init(_ title: String, key: String = "", enabled: Bool = true, _ run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(choose), keyEquivalent: key)
            target = self
            isEnabled = enabled
        }

        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func choose() { run() }
    }
}
