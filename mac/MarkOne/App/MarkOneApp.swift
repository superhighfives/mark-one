// Mark One: installs the Mark One camera extension, which makes an Olympus
// OM-D E-M5 available as a camera in video apps.

import SwiftUI
import SystemExtensions

@main
struct MarkOneApp: App {
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var pipeline = Pipeline()

    var body: some Scene {
        WindowGroup {
            ContentView(installer: installer, pipeline: pipeline)
                .frame(width: 420)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mark One")
                .font(.title2.weight(.semibold))
            Text("Adds your E-M5 as a camera you can pick in FaceTime, Zoom, OBS and other video apps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install camera") { installer.activate() }
                    .keyboardShortcut(.defaultAction)
                Button("Remove camera") { installer.deactivate() }
            }
            Text(installer.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(pipeline.running ? "Stop" : "Start") {
                    pipeline.running ? pipeline.stop() : pipeline.start()
                }
                if pipeline.framesPerSecond > 0 {
                    Text(String(format: "%.0f frames per second", pipeline.framesPerSecond))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(pipeline.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

/// Installs and removes the camera extension embedded in the app.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Not installed yet."

    private let identifier = "com.superhighfives.markone.camera"
    private var removing = false

    func activate() {
        status = "Installing…"
        removing = false
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        status = "Removing…"
        removing = true
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
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if result == .willCompleteAfterReboot {
                status = "Restart your Mac to finish."
            } else {
                status = removing ? "Removed." : "Installed. Pick “Mark One” as the camera in your video app."
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            status = "Failed: \(error.localizedDescription)"
        }
    }
}
