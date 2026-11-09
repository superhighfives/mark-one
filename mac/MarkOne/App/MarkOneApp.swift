// Mark One: a menu bar app that installs the Mark One camera extension and
// feeds it from an Olympus OM-D E-M5, so the camera shows up in video apps.

import ServiceManagement
import SwiftUI
import SystemExtensions

@main
struct MarkOneApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var installer = ExtensionInstaller.shared
    @StateObject private var pipeline = Pipeline.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(installer: installer, pipeline: pipeline)
                .frame(width: 320)
        } label: {
            Image(systemName: pipeline.state == .streaming ? "video.fill"
                  : pipeline.state == .ready ? "video" : "video.slash")
        }
        .menuBarExtraStyle(.window)
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
            ExtensionInstaller.shared.activate()
            Pipeline.shared.run()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Pipeline.shared.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @Environment(\.openWindow) private var openWindow

    private func showFirmware() {
        openWindow(id: "firmware")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mark One")
                .font(.headline)
            PreviewView()
                .frame(width: 288, height: 162)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("Brightness")
                Slider(value: Binding(get: { Double(pipeline.brightness) },
                                      set: { pipeline.brightness = Int($0.rounded()) }),
                       in: -9...9, step: 1)
                Text(pipeline.brightness == 0 ? "0.0" : String(format: "%+.1f", Double(pipeline.brightness) / 3))
                    .font(.callout.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            HStack {
                Button(pipeline.focusing ? "Focusing…" : "Focus") { pipeline.focus() }
                    .disabled(pipeline.state != .streaming || pipeline.focusing || pipeline.continuousFocus)
                Spacer()
                Toggle("Continuous autofocus", isOn: $pipeline.continuousFocus)
            }
            Text(pipeline.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch pipeline.firmware {
            case .stock:
                Button("Set Up Camera…") { showFirmware() }
                    .buttonStyle(.borderedProminent)
            case .markOne(let revision) where revision < FirmwareImage.bundledRevision:
                Button("Update Camera…") { showFirmware() }
            default:
                EmptyView()
            }
            if pipeline.framesPerSecond > 0 {
                Text(String(format: "%.0f frames per second", pipeline.framesPerSecond))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !installer.installed {
                Text(installer.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install camera") { installer.activate() }
            }
            Divider()
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    } catch {
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Lock camera controls", isOn: $pipeline.lockControls)
                    Text("While Mark One uses the camera, only its power switch, dials and shutter half press work, so a bump can't change a setting or take a photo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Camera firmware…") { showFirmware() }
                    Text("Set up a camera, update or reinstall Mark One's firmware, or put Olympus's back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove camera") { installer.deactivate() }
                }
                .padding(.top, 6)
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
    }
}

/// Installs and removes the camera extension embedded in the app.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let shared = ExtensionInstaller()

    @Published var status = "Not installed yet."
    @Published var installed = false

    private let identifier = "com.superhighfives.markone.camera"
    private var removing = false

    func activate() {
        status = "Installing the camera…"
        removing = false
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
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            status = "Failed: \(error.localizedDescription)"
        }
    }
}

