// Mark One: a menu bar app that installs the Mark One camera extension and
// feeds it from an Olympus OM-D E-M5, so the camera shows up in video apps.

import SwiftUI

@main
struct MarkOneApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var installer = ExtensionInstaller.shared
    @StateObject private var pipeline = Pipeline.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(installer: installer, pipeline: pipeline)
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: pipeline.state == .streaming))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(installer: installer, pipeline: pipeline)
        }

        Window("Camera Firmware", id: "firmware") {
            FirmwareView(pipeline: pipeline)
        }
        .windowResizability(.contentSize)
    }
}

/// Installs the camera extension and starts watching for the camera at
/// launch, and closes the camera session before quitting. Quitting with it
/// open can leave macOS's camera service stuck, so the camera doesn't show
/// up again until it's unplugged.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            DockIcon.start()
            Preferences.shared.start(Pipeline.shared)
            ExtensionInstaller.shared.activate()
            Pipeline.shared.run()
            if WelcomeWindow.needed { WelcomeWindow.show() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Pipeline.shared.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Shows Mark One in the Dock and the app switcher while one of its windows
/// is open (setup, firmware, settings), so it isn't lost behind other apps.
/// Otherwise it lives only in the menu bar.
@MainActor
enum DockIcon {
    static func start() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // A closing window is still visible now; look once it's gone.
                DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
            }
        }
    }

    private static func update() {
        let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if open { NSApp.activate(ignoringOtherApps: true) }
    }
}
