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
    /// Whether the extension was switched on after Mark One opened, so Mark
    /// One has to be reopened to use the camera.
    @Published var needsReopen = false

    private let identifier = "com.superhighfives.markone.camera"
    private var removing = false
    private var check: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    /// When the extension was first seen on without its camera.
    private var enabledSince: Date?
    /// Whether an install or removal request is under way.
    private var pending = false

    func activate() {
        requested = true
        watch()
        status = "Installing the camera…"
        removing = false
        failed = false
        needsRestart = false
        pending = true
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
        needsReopen = false
        pending = true
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
            pending = false
            if result == .willCompleteAfterReboot {
                status = "Restart your Mac to finish."
            } else {
                if removing {
                    status = "Not installed"
                    installed = false
                } else {
                    // Finishing doesn't mean it's on: an extension turned off
                    // in System Settings stays off.
                    needsApproval = false
                    confirmCamera()
                }
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            pending = false
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
    /// What macOS says about the extension.
    enum State { case enabled, disabled, awaitingApproval, missing }

    /// Checks on the extension once an install request is done.
    private func confirmCamera() {
        check?.cancel()
        check = Task { @MainActor in await refresh() }
    }

    /// Brings the status in line with macOS's answer. Whether the extension
    /// is on comes from macOS, not the camera list: a running process doesn't
    /// see the camera appear once it's switched on (see "Processes don't see
    /// the camera come back" in NOTES.md).
    private func refresh() async {
        guard !removing, !pending, let state = await Self.state() else { return }
        switch state {
        case .enabled:
            if CameraSink.available {
                allowed(reopen: false)
            } else if await Self.cameraInFreshProcess() {
                allowed(reopen: true)
            } else {
                // On but not running, which only a restart fixes (see
                // "Camera extension updates" in NOTES.md). Give it a moment
                // to start first.
                let since = enabledSince ?? Date()
                enabledSince = since
                guard Date().timeIntervalSince(since) > 10, !needsRestart else { return }
                log.notice("The Mark One camera is on but didn't appear; asking for a restart")
                installed = false
                failed = true
                needsRestart = true
                status = "macOS installed the Mark One camera but didn’t start it. Restart your Mac to finish, then open Mark One."
            }
        case .awaitingApproval:
            installed = false
            needsApproval = true
            failed = false
            status = "Allow it in System Settings › General › Login Items & Extensions: click ⓘ beside Mark One and turn on Media Extension."
        case .disabled:
            turnedOff()
        case .missing:
            installed = false
            needsApproval = false
            if !failed { status = "Not installed" }
        }
    }

    /// The extension is on. `reopen` says Mark One started before it was, so
    /// it can't see its own camera until it's reopened, and FaceTime's video
    /// service can't either until it restarts.
    private func allowed(reopen: Bool) {
        let newly = !installed
        enabledSince = nil
        status = "Installed"
        installed = true
        needsApproval = false
        failed = false
        needsRestart = false
        needsReopen = reopen
        if newly { log.notice("The Mark One camera is on\(reopen ? "; Mark One needs reopening to use it" : "")") }
        if newly && reopen { VideoServices.restartFaceTimeService() }
    }

    /// The extension is installed but switched off in System Settings, so
    /// the steps to allow it apply again.
    private func turnedOff() {
        enabledSince = nil
        status = "Turned off in System Settings › General › Login Items & Extensions: click ⓘ beside Mark One and turn on Media Extension."
        installed = false
        needsApproval = true
        failed = false
        needsRestart = false
        needsReopen = false
    }

    /// Asks macOS about the extension every 2 seconds until it's on, then
    /// every 10, to follow it being switched on and off in System Settings.
    /// Not while Mark One is waiting to be reopened.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(installed && !needsRestart ? 10 : 2))
                if !needsReopen { await refresh() }
            }
        }
    }

    /// What macOS says about the extension, or nil if it couldn't say.
    private static func state() async -> State? {
        await withCheckedContinuation { done in
            let probe = PropertiesProbe { properties in
                done.resume(returning: properties.map { list in
                    let current = list.filter { !$0.isUninstalling }
                    if current.contains(where: { $0.isEnabled && !$0.isAwaitingUserApproval }) { return .enabled }
                    if current.contains(where: \.isAwaitingUserApproval) { return .awaitingApproval }
                    return current.isEmpty ? .missing : .disabled
                })
            }
            let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: "com.superhighfives.markone.camera", queue: .main)
            request.delegate = probe
            probe.keepAlive = probe
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    /// Whether a new process sees the Mark One camera: Mark One's own
    /// executable, run with --camera-present (see MarkOneApp).
    private static func cameraInFreshProcess() async -> Bool {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--camera-present"]
                let output = Pipe()
                process.standardOutput = output
                do { try process.run() } catch { done.resume(returning: false); return }
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                done.resume(returning: text.hasPrefix("1"))
            }
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
