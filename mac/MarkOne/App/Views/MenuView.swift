// The menu bar panel: what the camera is doing, and the one thing to do next.

import SwiftUI

struct MenuView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline
    @Environment(\.openSettings) private var openSettings

    private enum Mode { case install, waiting, off, firmware, connected }

    private var mode: Mode {
        if !installer.installed && (installer.needsApproval || installer.failed) { return .install }
        switch pipeline.state {
        case .ready, .streaming: return .connected
        case .waiting:
            switch pipeline.problem {
            case .wrongFirmware: return .firmware
            case .cameraOff: return .off
            case nil: return .waiting
            }
        }
    }

    private var headline: String {
        switch mode {
        case .install: "Needs your OK"
        case .waiting: "No camera yet"
        case .off: "Camera off"
        case .firmware: "Needs firmware"
        case .connected: pipeline.state == .streaming ? "Live" : "Ready"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch mode {
            case .install: install
            case .waiting: waiting
            case .off: off
            case .firmware: firmware
            case .connected: connected
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mark One").font(.headline)
                Text(headline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pipeline.framesPerSecond > 0 {
                Text(String(format: "%.0f fps", pipeline.framesPerSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: States

    private var install: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(installer.failed ? "The camera didn’t install" : "Allow the Mark One camera")
                .font(.title3.weight(.semibold))
            Text(installer.failed
                 ? installer.status
                 : "macOS asks before an app adds a camera. Turn on Mark One under Camera Extensions in System Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if installer.failed {
                Button("Try Again") { installer.activate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Open System Settings") { ExtensionInstaller.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your E-M5").font(.title3.weight(.semibold))
                Text("Mark One sets the camera up as soon as it sees it.").foregroundStyle(.secondary)
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, text: "On the camera, set **USB Mode** to **MTP**.")
                    StepRow(number: 2, text: "Plug it into this Mac with a USB cable.")
                    StepRow(number: 3, text: "Switch the camera on.")
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(pipeline.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                CameraSketch(faded: true)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Camera off").font(.title3.weight(.semibold))
                Text("Switch it back on, or plug it in again, and Mark One sets it up again by itself.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var firmware: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This camera needs the Mark One firmware", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .symbolRenderingMode(.multicolor)
                    Text(pipeline.status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Set Up Firmware…") { WelcomeWindow.show(at: .firmware) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private var connected: some View {
        let live = pipeline.state == .streaming
        return VStack(alignment: .leading, spacing: 12) {
            PreviewView()
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge().padding(8) }
                }
                .overlay {
                    if !live {
                        Text("Starting the camera…")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            Text(live ? "Choose **Mark One** as the camera in any video app. Nothing is saved to the card."
                      : "Choose **Mark One** as the camera in FaceTime, Zoom or any video app. Mark One presses REC for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    BrightnessControl(pipeline: pipeline)
                    HStack {
                        Button(pipeline.focusing ? "Focusing…" : "Focus") { pipeline.focus() }
                            .disabled(!live || pipeline.focusing || pipeline.continuousFocus)
                        Spacer()
                        Toggle("Continuous autofocus", isOn: $pipeline.continuousFocus)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            Divider().padding(.horizontal, -14)
            HStack {
                Button("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit Mark One") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
        }
    }
}
