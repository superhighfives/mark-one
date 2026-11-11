// Updates through Sparkle, from the feed in Info.plist (SUFeedURL). Only
// release builds have a feed (scripts/release.sh sets it); builds from
// source don't update. Updates are signed with Mark One's own EdDSA key; its public half is SUPublicEDKey
// and the private half is in the release Mac's keychain, under the account
// "mark-one" (see scripts/release.sh).

import AppKit
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Whether this build gets updates: release builds only.
    static let enabled = !((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "").isEmpty

    /// False while a check is already running.
    @Published private(set) var canCheck = false

    /// Whether Sparkle checks once a day on its own.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    /// Starts the daily checks. Call once at launch.
    func start() {
        guard Updater.enabled else { return }
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheck)
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Holds off scheduled checks during a call, so an update prompt never
    /// lands mid-call. Checks from the button always run.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        let streaming = MainActor.assumeIsolated { Pipeline.shared.state == .streaming }
        if streaming {
            throw NSError(domain: "MarkOne.Updater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The camera is in use."])
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Mark One lives in the menu bar, so a scheduled update's window would
    /// open behind other apps. Bringing Mark One forward first keeps it in
    /// view.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
    }
}
