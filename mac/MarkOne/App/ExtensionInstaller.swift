// Installs the Mark One camera extension, which macOS asks the user to
// allow once in System Settings.

import AppKit
import os
import SystemExtensions

private let log = Logger(subsystem: "com.superhighfives.markone", category: "extension")

/// Installs and removes the camera extension embedded in the app.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let shared = ExtensionInstaller()

    @Published var status = "Not installed"
    @Published var installed = false
    /// Whether macOS is waiting for the user to allow the camera in System Settings.
    @Published var needsApproval = false
    /// Whether installing failed, so the user needs to try again.
    @Published var failed = false
    /// Whether macOS installed the extension but didn't start it, which
    /// only a restart fixes. Also sets `failed`.
    @Published var needsRestart = false

    private let identifier = "com.superhighfives.markone.camera"
    private var removing = false
    private var check: Task<Void, Never>?
    private var watching: Task<Void, Never>?

    func activate() {
        requested = true
        watch()
        status = "Installing the camera…"
        removing = false
        failed = false
        needsRestart = false
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private var requested = false

    /// Asks for the extension unless that's already been asked this launch.
    func activateOnce() {
        guard !requested else { return }
        activate()
    }

    func deactivate() {
        status = "Removing…"
        removing = true
        installed = false
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Replacing a running camera extension can leave none running until
        // a restart (see NOTES.md), so only replace it with a different one.
        let same = existing.bundleVersion == ext.bundleVersion && existing.bundleShortVersion == ext.bundleShortVersion
        return same && existing.isEnabled && !existing.isAwaitingUserApproval ? .cancel : .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            status = "Allow it in System Settings › General › Login Items & Extensions: click ⓘ beside Mark One and turn on Media Extension."
            needsApproval = true
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if result == .willCompleteAfterReboot {
                status = "Restart your Mac to finish."
            } else {
                if removing {
                    status = "Not installed"
                    installed = false
                } else {
                    // Finishing doesn't mean it's on: an extension turned off
                    // in System Settings stays off. The camera showing up
                    // says it's on.
                    needsApproval = false
                    confirmCamera()
                }
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            // Cancelled above because this version is already installed.
            if !removing, (error as? OSSystemExtensionError)?.code == .requestCanceled {
                needsApproval = false
                confirmCamera()
                return
            }
            status = "Failed: \(error.localizedDescription)"
            failed = true
        }
    }
}

extension ExtensionInstaller {
    /// Checks that the Mark One camera shows up. After an update, macOS can
    /// switch to the new extension without starting it, and then there's no
    /// camera until the Mac restarts (see "Camera extension updates" in
    /// NOTES.md).
    private func confirmCamera() {
        check?.cancel()
        check = Task { @MainActor in
            for _ in 0..<20 {
                if CameraSink.available { allowed(); return }
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            // Turned off in System Settings, or on but not started.
            if await Self.enabled() == false {
                turnedOff()
                return
            }
            log.notice("The Mark One camera didn't appear after installing; asking for a restart")
            installed = false
            failed = true
            needsRestart = true
            status = "macOS installed the Mark One camera but didn’t start it. Restart your Mac to finish, then open Mark One."
        }
    }

    private func allowed() {
        status = "Installed"
        installed = true
        needsApproval = false
        failed = false
        needsRestart = false
    }

    /// The extension is installed but switched off in System Settings, so
    /// the steps to allow it apply again.
    private func turnedOff() {
        status = "Turned off in System Settings › General › Login Items & Extensions: click ⓘ beside Mark One and turn on Media Extension."
        installed = false
        needsApproval = true
        failed = false
        needsRestart = false
    }

    /// Follows the camera appearing and disappearing, as the extension is
    /// turned on and off in System Settings, every two seconds while Mark
    /// One runs. Reading the device list is cheap; macOS is only asked about
    /// the extension when it changes.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { @MainActor in
            var last = CameraSink.available
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = CameraSink.available
                guard now != last else { continue }
                last = now
                if removing { continue }
                if now {
                    check?.cancel()
                    allowed()
                } else if await Self.enabled() == false {
                    turnedOff()
                }
            }
        }
    }

    /// Whether macOS has the extension installed and switched on, or nil if
    /// it couldn't say.
    private static func enabled() async -> Bool? {
        await withCheckedContinuation { done in
            let probe = PropertiesProbe { properties in
                done.resume(returning: properties.map { list in
                    list.contains { $0.isEnabled && !$0.isUninstalling && !$0.isAwaitingUserApproval }
                })
            }
            let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: "com.superhighfives.markone.camera", queue: .main)
            request.delegate = probe
            probe.keepAlive = probe
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    /// Opens the pane in System Settings where camera extensions are allowed.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Answers one properties request: the versions of the extension macOS
/// has, or nil if it failed.
private final class PropertiesProbe: NSObject, OSSystemExtensionRequestDelegate {
    private var answer: (([OSSystemExtensionProperties]?) -> Void)?
    /// Holds the probe until it answers; the request's delegate is weak.
    var keepAlive: PropertiesProbe?

    init(_ answer: @escaping ([OSSystemExtensionProperties]?) -> Void) {
        self.answer = answer
    }

    private func finish(_ properties: [OSSystemExtensionProperties]?) {
        answer?(properties)
        answer = nil
        keepAlive = nil
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        finish(properties)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { finish(nil) }
    // Comes after foundProperties, so this only answers if that never came.
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) { finish(nil) }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .cancel }
}
