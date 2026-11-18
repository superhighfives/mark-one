// The app's own settings: how it shows itself and when it tells you
// something. The camera's settings live in Pipeline.

import AppKit
import Combine
import UserNotifications

@MainActor
final class Preferences: NSObject, ObservableObject {
    static let shared = Preferences()

    /// Whether the panel's preview is flipped left to right, like a mirror.
    @Published var mirrorPreview = UserDefaults.standard.bool(forKey: "MirrorPreview") {
        didSet { UserDefaults.standard.set(mirrorPreview, forKey: "MirrorPreview") }
    }

    /// Whether Mark One shows in the Dock as well as the menu bar.
    @Published var showInDock = UserDefaults.standard.bool(forKey: "ShowInDock") {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "ShowInDock")
            applyDock()
            // Leaving the Dock deactivates the app; keep Settings in front.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Whether to post a notification when the camera is switched off or
    /// unplugged while a video app is using it.
    @Published var notifyWhenOff = UserDefaults.standard.object(forKey: "NotifyWhenCameraOff") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(notifyWhenOff, forKey: "NotifyWhenCameraOff")
            if notifyWhenOff && !oldValue { askToNotify() }
        }
    }

    /// Whether to log what Mark One is doing once a minute (see Diagnostics).
    @Published var detailedLogging = UserDefaults.standard.bool(forKey: "DetailedLogging") {
        didSet {
            UserDefaults.standard.set(detailedLogging, forKey: "DetailedLogging")
            Diagnostics.detailed.value = detailedLogging
        }
    }

    /// Set when macOS won't let Mark One post notifications.
    @Published private(set) var notificationsDenied = false

    private var watching: Set<AnyCancellable> = []
    /// Set between recording ending and the pipeline saying why.
    private var streamEnded = false

    /// Applies the Dock and logging settings and starts watching for the
    /// camera turning off. Call once at launch.
    func start(_ pipeline: Pipeline) {
        applyDock()
        Diagnostics.detailed.value = detailedLogging
        Diagnostics.start()
        UNUserNotificationCenter.current().delegate = self
        if notifyWhenOff { askToNotify() }
        // Both publish before the value changes, so `pipeline.state` is
        // still the old state here. When the camera goes away mid-recording,
        // the state goes from streaming to waiting, then the problem
        // becomes cameraOff.
        pipeline.$state.sink { [weak self, weak pipeline] state in
            self?.streamEnded = pipeline?.state == .streaming && state == .waiting
        }.store(in: &watching)
        pipeline.$problem.sink { [weak self] problem in
            guard let self, problem == .cameraOff, streamEnded else { return }
            streamEnded = false
            if notifyWhenOff { postCameraOff() }
        }.store(in: &watching)
    }

    private func applyDock() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// Asks macOS for permission to notify, the first time; if it's been
    /// refused, turns the setting back off.
    private func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.notificationsDenied = !granted
                if !granted { self.notifyWhenOff = false }
            }
        }
    }

    private func postCameraOff() {
        let content = UNMutableNotificationContent()
        content.title = "Camera off"
        content.body = "The E-M5 (Mark I) was switched off or unplugged, so video apps aren’t getting its picture. Switch it back on and Mark One sets it up again."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "camera-off", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension Preferences: UNUserNotificationCenterDelegate {
    /// Shows the notification even while Mark One's panel or Settings is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
