// The menu bar panel: what the camera is doing, and the one thing to do next.

import SwiftUI

struct MenuView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private static let width: CGFloat = 320
    private static let padding: CGFloat = 14

    private enum Mode { case install, updating, waiting, photos, off, noCard, firmware, connected }

    private var mode: Mode {
        if !installer.installed && (installer.needsApproval || installer.failed) { return .install }
        if pipeline.updating { return .updating }
        switch pipeline.state {
        case .ready, .streaming: return .connected
        case .waiting:
            if pipeline.firmware == .stock { return .firmware }
            switch pipeline.problem {
            case .wrongFirmware: return .firmware
            case .cameraOff: return .off
            case .connectedForPhotos: return .photos
            case .noCard: return .noCard
            case nil: return .waiting
            }
        }
    }

    /// Under the name. Nothing while connected: the preview shows it.
    private var headline: String? {
        switch mode {
        case .install: installer.needsRestart ? "Needs a restart" : "Needs your OK"
        case .updating: "Updating the camera"
        case .waiting: "No camera yet"
        case .photos: "Connected for photos"
        case .off: "Camera off"
        case .noCard: "No card"
        case .firmware: "Needs firmware"
        case .connected: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch mode {
            case .install: install
            case .updating: updating
            case .waiting: waiting
            case .photos: photos
            case .off: off
            case .noCard: noCard
            case .firmware: firmware
            case .connected: connected
            }
            footer
        }
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mark One").font(.headline)
                if let headline {
                    Text(headline).font(.caption).foregroundStyle(.secondary)
                }
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
        VStack(alignment: .leading, spacing: 12) {
            message(installer.notInApplications ? "Move Mark One to Applications"
                    : installer.needsRestart ? "Restart to finish" : installer.failed ? "The camera didn’t install" : "Allow the Mark One camera",
                    Text(installer.failed
                         ? installer.status
                         : "macOS asks before an app adds a camera. In System Settings › General › Login Items & Extensions, click ⓘ beside Mark One and turn on Media Extension."))
            if installer.failed {
                Button(installer.notInApplications ? "Quit and Move" : installer.needsRestart ? "Check Again" : "Try Again") {
                    if installer.notInApplications { NSApp.terminate(nil) } else { installer.activate() }
                }
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
            message("Connect your E-M5 (Mark I)", Text("Mark One sets the camera up as soon as it sees it."))
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, text: "Plug it into this Mac with a USB cable.")
                    StepRow(number: 2, text: "Switch the camera on.")
                    StepRow(number: 3, text: "If it asks how to connect, choose **Webcam**.")
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
        message("Connected for photos",
                Text("Mark One leaves the camera alone so photo apps can use it. To use it as a webcam, plug it in again and choose **Webcam** on its screen."))
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                CameraSketch(faded: true)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
            }
            message("Camera off", Text("Switch it back on, or plug it in again, and Mark One sets it up again by itself."))
        }
    }

    private var noCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            message("Put a card in the camera",
                    Text("The camera only records with a memory card in. Mark One doesn't save anything to it. With Mark One's latest camera firmware, it doesn't need one."))
            if pipeline.firmware?.updateAvailable == true {
                Button("Update Camera…") { closePanel(); openWindow.firmware() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var updating: some View {
        VStack(alignment: .leading, spacing: 12) {
            message("Updating the camera",
                    Text(pipeline.install?.phase == .switchOffFirst
                         ? "Switch the camera off and on to carry on."
                         : "Leave the camera alone, and don't unplug it, until it's done. Mark One carries on by itself."))
            Button("Show Progress") { closePanel(); openWindow.firmware() }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private var firmware: some View {
        VStack(alignment: .leading, spacing: 12) {
            message("Install Mark One firmware", icon: "exclamationmark.triangle.fill", Text(pipeline.status))
            Button("Set Up Camera…") { closePanel(); openWindow.firmware() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private var connected: some View {
        let live = pipeline.state == .streaming
        return VStack(alignment: .leading, spacing: 12) {
            // A set height: the panel squashes anything that can shrink, and
            // an aspect ratio alone lets the preview collapse.
            PreviewView(mirrored: preferences.mirrorPreview)
                .frame(height: (Self.width - 2 * Self.padding) * 9 / 16)
                .overlay { PreviewOverlay(busy: pipeline.busy, focusing: pipeline.focusing) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge().padding(8) }
                }
            // Both messages take the same space, so the panel keeps its size
            // when a call starts.
            ZStack(alignment: .topLeading) {
                Text("Choose **Mark One** as the camera in FaceTime, Zoom or any video app. Mark One presses REC for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(live ? 0 : 1)
                    .accessibilityHidden(live)
                VStack(alignment: .leading, spacing: 2) {
                    Text("In use by \(pipeline.activeApp ?? "")")
                        .fontWeight(.semibold)
                        .opacity(pipeline.activeApp == nil ? 0 : 1)
                    Text("Nothing is saved to the card. Recording stops \(pipeline.grace.duration) after the call ends.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(live ? 1 : 0)
                .accessibilityHidden(!live)
            }
            if let battery = pipeline.battery, CameraBattery(level: battery) != .full {
                Label("The camera's battery is low. Charge it soon, or use a dummy battery with a power adapter.",
                      systemImage: "battery.25percent")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pipeline.firmware?.updateAvailable == true {
                HStack {
                    Label("New camera firmware", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Update Camera…") { closePanel(); openWindow.firmware() }
                }
                .font(.callout)
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ControlRow("Brightness") {
                        BrightnessControl(pipeline: pipeline, showsLabel: false)
                    }
                    ControlRow("White balance") {
                        PopUp(selection: $pipeline.whiteBalance, options: Pipeline.WhiteBalance.allCases) { $0.label }
                            .accessibilityLabel("White balance")
                    }
                    ControlRow("Picture mode") {
                        PopUp(selection: $pipeline.pictureMode, options: Pipeline.PictureMode.allCases) { $0.label }
                            .accessibilityLabel("Picture mode")
                    }
                    ControlRow("Focus") {
                        HStack(spacing: 6) {
                            Segments(selection: $pipeline.continuousFocus, options: [true, false]) { $0 ? "Always" : "Once" }
                                .accessibilityLabel("Autofocus")
                            // Focuses once, when focus is set to Once.
                            Button {
                                pipeline.focus()
                            } label: {
                                // Both stay in place, so the button keeps its size.
                                ZStack {
                                    Image(systemName: "scope").opacity(pipeline.focusing ? 0 : 1)
                                    ProgressView().controlSize(.mini).opacity(pipeline.focusing ? 1 : 0)
                                }
                            }
                            .disabled(!live || pipeline.focusing || pipeline.continuousFocus)
                            .help("Focus now")
                            .accessibilityLabel(pipeline.focusing ? "Focusing" : "Focus now")
                        }
                    }
                }
            }
        }
    }

    /// A state's title and what it means, spaced the same in every state.
    private func message(_ title: String, icon: String? = nil, _ text: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).symbolRenderingMode(.multicolor)
                }
                Text(title)
            }
            .font(.title3.weight(.semibold))
            text
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Divider().padding(.horizontal, -Self.padding)
            HStack {
                Button("Settings…") {
                    closePanel()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit Mark One") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(pipeline.updating)
                    .help(pipeline.updating ? "Mark One is updating the camera." : "")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
        }
    }

    /// Closes this panel, so a window it opens isn't left behind it. While
    /// it's open, the panel is the key window.
    private func closePanel() {
        NSApp.keyWindow?.close()
    }
}
