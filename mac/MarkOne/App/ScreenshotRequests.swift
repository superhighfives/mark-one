// Opens a window when scripts/capture-screenshots.swift asks, so the website's
// screenshots need no clicking. The script posts a distributed notification
// named "com.superhighfives.markone.show" with the window's name as its
// object: panel, welcome (on its firmware step), firmware or settings, or
// none to close them all. Each request closes the windows from the last one.

import AppKit
import SwiftUI

@MainActor
enum ScreenshotRequests {
    static let name = Notification.Name("com.superhighfives.markone.show")

    /// Starts listening. `openWindow` and `openSettings` come from a view
    /// that's always there: the menu bar icon.
    static func start(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let window = note.object as? String
            MainActor.assumeIsolated { show(window, openWindow: openWindow, openSettings: openSettings) }
        }
    }

    private static var observer: NSObjectProtocol?

    private static func show(_ window: String?, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        closeAll()
        switch window {
        case "panel": statusButton?.performClick(nil)
        case "welcome": WelcomeWindow.show(at: .firmware)
        case "firmware": openWindow.firmware()
        case "settings":
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        default: break
        }
    }

    private static func closeAll() {
        for window in NSApp.windows where window.isVisible {
            if window.styleMask.contains(.titled) {
                window.close()
            } else if isPanel(window) {
                // Clicking the icon again closes the panel the usual way.
                statusButton?.performClick(nil)
            }
        }
    }

    /// The menu bar icon's button, which opens and closes the panel.
    private static var statusButton: NSButton? {
        NSApp.windows
            .first { String(describing: type(of: $0)).contains("StatusBarWindow") }?
            .contentView.flatMap(findButton)
    }

    private static func findButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews { if let button = findButton(in: subview) { return button } }
        return nil
    }

    private static func isPanel(_ window: NSWindow) -> Bool {
        window is NSPanel && !String(describing: type(of: window)).contains("StatusBarWindow")
    }
}

/// The menu bar icon. It's always on screen, so it starts the listener.
struct MenuBarLabel: View {
    let recording: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: MenuBarIcon.image(recording: recording))
            .onAppear {
                ScreenshotRequests.start(openWindow: openWindow, openSettings: openSettings)
                #if DEBUG
                Snapshots.run(openSettings: openSettings)
                #endif
            }
    }
}
