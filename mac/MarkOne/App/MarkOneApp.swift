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
    }
}

/// Installs the camera extension and starts watching for the camera at
/// launch, and closes the camera session before quitting. Quitting with it
/// open can leave macOS's camera service stuck, so the camera doesn't show
/// up again until it's unplugged.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
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
