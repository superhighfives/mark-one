// Installs the Mark One camera extension, which macOS asks the user to
// allow once in System Settings.

import AppKit
import SystemExtensions

/// Installs and removes the camera extension embedded in the app.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let shared = ExtensionInstaller()

    @Published var status = "Not installed yet."
    @Published var installed = false
    /// Whether macOS is waiting for the user to allow the camera in System Settings.
    @Published var needsApproval = false
    /// Whether installing failed, so the user needs to try again.
    @Published var failed = false

    private let identifier = "com.superhighfives.markone.camera"
    private var removing = false

    func activate() {
        status = "Installing the camera…"
        removing = false
        failed = false
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
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
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            status = "Allow it in System Settings › General › Login Items & Extensions › Camera Extensions."
            needsApproval = true
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if result == .willCompleteAfterReboot {
                status = "Restart your Mac to finish."
            } else {
                status = removing ? "Removed." : "Installed."
                installed = !removing
                needsApproval = false
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            status = "Failed: \(error.localizedDescription)"
            failed = true
        }
    }
}

extension ExtensionInstaller {
    /// Opens the pane in System Settings where camera extensions are allowed.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
