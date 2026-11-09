// The menu bar panel: what the camera is doing, and the one thing to do next.

import SwiftUI

struct MenuView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private enum Mode { case install, waiting, photos, off, firmware, connected }

    private var mode: Mode {
        if !installer.installed && (installer.needsApproval || installer.failed) { return .install }
        switch pipeline.state {
        case .ready, .streaming: return .connected
        case .waiting:
            if pipeline.firmware == .stock { return .firmware }
            switch pipeline.problem {
            case .wrongFirmware: return .firmware
            case .cameraOff: return .off
            case .connectedForPhotos: return .photos
            case nil: return .waiting
            }
        }
    }

    private var headline: String {
        switch mode {
        case .install: "Needs your OK"
        case .waiting: "No camera yet"
        case .photos: "Connected for photos"
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
            case .photos: photos
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
            if mode == .connected || mode == .firmware, let battery = pipeline.battery {
                BatteryLevel(level: battery)
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
                Text("Connect your E-M5 (Mark I)").font(.title3.weight(.semibold))
                Text("Mark One sets the camera up as soon as it sees it.").foregroundStyle(.secondary)
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, text: "Plug it into this Mac with a USB cable.")
                    StepRow(number: 2, text: "Switch the camera on.")
                    StepRow(number: 3, text: "Choose **Webcam** on its screen.")
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

    private var photos: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connected for photos").font(.title3.weight(.semibold))
            Text("Mark One leaves the camera alone so photo apps can use it. To use it as a webcam, plug it in again and choose **Webcam** on its screen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Button("Set Up Camera…") { openWindow.firmware() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private var connected: some View {
        let live = pipeline.state == .streaming
        return VStack(alignment: .leading, spacing: 12) {
            PreviewView(mirrored: preferences.mirrorPreview)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PreviewOverlay(busy: pipeline.busy, focusing: pipeline.focusing) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge().padding(8) }
                }
            VStack(alignment: .leading, spacing: 2) {
                if live, let app = pipeline.activeApp {
                    Text("In use by \(app)").fontWeight(.semibold)
                }
                Text(live ? "Nothing is saved to the card. Recording stops \(pipeline.grace.duration) after the call ends."
                          : "Choose **Mark One** as the camera in FaceTime, Zoom or any video app. Mark One presses REC for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pipeline.firmware?.updateAvailable == true {
                HStack {
                    Label("New camera firmware", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Update Camera…") { openWindow.firmware() }
                }
                .font(.callout)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    BrightnessControl(pipeline: pipeline)
                    Picker("White balance", selection: $pipeline.whiteBalance) {
                        ForEach(Pipeline.WhiteBalance.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Picture mode", selection: $pipeline.pictureMode) {
                        ForEach(Pipeline.PictureMode.allCases) { Text($0.label).tag($0) }
                    }
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
