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
    static var statusButton: NSButton? {
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

/// The menu bar icon. It's always on screen, so it starts the listener and
/// the right-click menu.
struct MenuBarLabel: View {
    let recording: Bool
    let focusing: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the index line has turned, or nil while it blinks off.
    @State private var turn: Double? = 0
    /// How far in to the centre it reaches.
    @State private var reach = 0.0
    /// Two o'clock: the index line swings this far each way.
    private static let swing = 2.0 / 12
    /// Seconds for a swing from 2 o'clock to 10 and back.
    private static let swingTime = 1.8
    /// Seconds to reach in to the centre, or draw back.
    private static let reachTime = 0.2
    /// Seconds to swing back to 12 o'clock.
    private static let returnTime = 0.3

    /// Calls `step` with 0 to 1, eased out, for `duration` seconds or until
    /// the task is cancelled.
    private func ease(over duration: TimeInterval, _ step: (Double) -> Void) async {
        let start = Date()
        while !Task.isCancelled {
            let done = min(1, Date().timeIntervalSince(start) / duration)
            step(1 - pow(1 - done, 3))
            if done == 1 { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(recording: recording, turn: turn, reach: reach))
            // While focusing, the index line reaches in to the centre, then
            // swings between 2 and 10 o'clock. After, it swings back to 12,
            // then draws back to its usual short line. With Reduce Motion
            // on, it blinks instead.
            .task(id: focusing) {
                if reduceMotion {
                    reach = 0
                    guard focusing else { turn = 0; return }
                    let start = Date()
                    while !Task.isCancelled {
                        turn = Int(Date().timeIntervalSince(start) * 4) % 2 == 0 ? 0 : nil
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                } else if focusing {
                    // Out to the centre at 12 o'clock, then swing.
                    let fromTurn = turn ?? 0, fromReach = reach
                    await ease(over: Self.reachTime) {
                        turn = fromTurn * (1 - $0)
                        reach = fromReach + (1 - fromReach) * $0
                    }
                    let start = Date()
                    while !Task.isCancelled {
                        turn = Self.swing * sin(Date().timeIntervalSince(start) / Self.swingTime * 2 * .pi)
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                } else {
                    // Back to 12 o'clock, then in to the usual short line.
                    let fromTurn = turn ?? 0
                    await ease(over: Self.returnTime) { turn = fromTurn * (1 - $0) }
                    let fromReach = reach
                    await ease(over: Self.reachTime) { reach = fromReach * (1 - $0) }
                }
            }
            .onAppear {
                ScreenshotRequests.start(openWindow: openWindow, openSettings: openSettings)
                StatusMenu.start(openWindow: openWindow, openSettings: openSettings)
                #if DEBUG
                Snapshots.run(openSettings: openSettings)
                #endif
            }
    }
}
