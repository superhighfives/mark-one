// The Camera Firmware window. A camera with Olympus's firmware gets Mark
// One's from the SD card. One with Mark One's firmware can update or
// reinstall it over USB, go back to Olympus's firmware over USB, or report
// an older version so Olympus's OM Workspace offers to reinstall 2.3.

import Combine
import SwiftUI

struct FirmwareView: View {
    @ObservedObject var pipeline: Pipeline
    @State private var step = Step.start
    @State private var action = Action.setUp
    @State private var understood = false
    @State private var image: FirmwareImage?
    @State private var downloaded = 0.0
    @State private var cards: [URL] = []
    @State private var error: String?

    enum Step { case start, confirm, preparing, card, writing, camera, ready, usb, omWorkspace }

    enum Action {
        /// Mark One's firmware onto a stock camera, from the SD card.
        case setUp
        /// Mark One's firmware over USB, newer or the same.
        case update
        /// Olympus's firmware over USB.
        case restore
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var revision: Int? {
        if case .markOne(let revision) = pipeline.firmware { return revision }
        return nil
    }
    private var overUSB: Bool { pipeline.firmware.map(Firmware.canUpdateOverUSB) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(tick) { _ in if step == .card { cards = FirmwareInstall.cards() } }
        .onChange(of: pipeline.firmware) { _, firmware in
            // The camera is back with Mark One's firmware after a card install.
            if step == .camera, case .markOne = firmware { step = .ready }
        }
    }

    private var title: String {
        switch step {
        case .start where overUSB, .omWorkspace: "Camera firmware"
        case .confirm, .preparing, .usb:
            switch action {
            case .setUp: "Set up your camera"
            case .update: "Install Mark One's firmware"
            case .restore: "Restore Olympus's firmware"
            }
        default: "Set up your camera"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .start:
            // A Mark One build from before USB updates reinstalls from the card.
            if overUSB { manage } else { setUpIntro }
        case .ready: ready
        case .confirm: confirm
        case .preparing: preparing
        case .card: card
        case .writing: ProgressView("Writing to the card…")
        case .camera: cameraSteps
        case .usb: usb
        case .omWorkspace: omWorkspace
        }
    }


    private var manage: some View {
        VStack(alignment: .leading, spacing: 14) {
            let current = revision ?? 0
            let bundled = FirmwareImage.bundledRevision
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: current >= bundled ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(current >= bundled ? .green : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mark One's firmware, revision \(current)").fontWeight(.semibold)
                        Text(current >= bundled ? "Up to date." : "Revision \(bundled) is ready to install over USB.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if current < bundled {
                        Button("Update…") { begin(.update) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    if current >= bundled {
                        choice("Reinstall", "Install revision \(current) again, if something seems wrong.", "Reinstall…") {
                            begin(.update)
                        }
                        Divider().padding(.leading, 14)
                    }
                    choice("Restore Olympus's firmware",
                           "Put firmware 2.3 back. You can set the camera up for Mark One again later.",
                           "Restore…") {
                        begin(.restore)
                    }
                    Divider().padding(.leading, 14)
                    choice("Prepare for OM Workspace",
                           "Report firmware 1.0 until the camera is switched off, so OM Workspace offers 2.3.",
                           "Prepare…") {
                        pipeline.reportOlderVersion()
                        step = .omWorkspace
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { closeWindow() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func choice(_ title: String, _ detail: String, _ button: String,
                        _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) { Text(button).frame(minWidth: 80) }
        }
        .padding(14)
    }

    private var omWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pipeline.reportsOlderVersion {
                Label("The camera now reports firmware 1.0", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 8) {
                    numbered(1, "Keep the camera switched on from now on. Switching it off undoes this.")
                    numbered(2, "Quit Mark One, unplug the camera, and connect it to the computer with OM Workspace. Choose Storage on the camera.")
                    numbered(3, "In OM Workspace, choose Camera › Update. It offers firmware 2.3. Follow its steps, and leave the camera alone until it's done.")
                }
                Text("OM Workspace on a Mac needs a system extension and lowered security settings, so a Windows PC is the easier choice. Restore Olympus's Firmware here does the same job without OM Workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Changing the version the camera reports…")
                }
            }
            HStack {
                Spacer()
                Button("Done") { step = .start; closeWindow() }.keyboardShortcut(.defaultAction)
            }
        }
    }


    private func begin(_ action: Action) {
        self.action = action
        understood = false
        error = nil
        step = .confirm
    }

    private var setUpIntro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mark One needs its own firmware on your E-M5 (Mark I). It's Olympus's firmware 2.3 with a few changes that let the camera work as a webcam. Mark One downloads Olympus's firmware, adds its changes, and puts the result on your SD card. You install it from the card once; later updates happen over USB.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continue") { begin(.setUp) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action {
            case .setUp: EmptyView()
            case .update:
                Text("Mark One sends its firmware to the camera over USB. It takes about two minutes. [How updates work](https://superhighfives.com/mark-one/help#updates)")
                    .fixedSize(horizontal: false, vertical: true)
            case .restore:
                Text("Mark One puts Olympus's firmware 2.3 back on the camera over USB. [How going back works](https://superhighfives.com/mark-one/help#going-back)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Installing firmware has a risk", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text((action == .restore ? "" : "This firmware is unofficial, and not supported by Olympus or OM System. ")
                         + "If the camera loses power or is unplugged while it installs, it may not start again. Use a charged battery and leave it alone until it's done.")
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I understand, and I accept the risk", isOn: $understood)
                }
                .padding(4)
            }
            if lowBattery {
                Label("The camera's battery is low. Charge it before installing.", systemImage: "battery.25percent")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { step = .start }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action == .setUp ? "Continue" : action == .restore ? "Restore" : "Install") { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood || lowBattery)
            }
        }
    }

    /// Whether a USB install should wait for a charge. The camera reports
    /// 100 when full, then 50 once its own battery icon flashes empty.
    /// Setting up from the card happens with the camera unplugged, so Mark
    /// One can't check it then.
    private var lowBattery: Bool {
        guard action != .setUp, let level = pipeline.battery else { return false }
        return CameraBattery(level: level) != .full
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: downloaded) { Text("Getting Olympus's firmware…") }
            Text("About 47 MB from Olympus's update server, the first time only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func prepare() {
        error = nil
        downloaded = 0
        step = .preparing
        let action = action
        Task {
            do {
                let progress: @Sendable (Double) -> Void = { fraction in Task { @MainActor in downloaded = fraction } }
                let built = action == .restore ? try await FirmwareImage.olympus(progress: progress)
                                               : try await FirmwareImage.make(progress: progress)
                image = built
                if action == .setUp {
                    cards = FirmwareInstall.cards()
                    step = .card
                } else {
                    step = .usb
                    pipeline.installOverUSB(built)
                }
            } catch {
                self.error = error.localizedDescription
                step = .confirm
            }
        }
    }


    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Take the SD card out of your camera and put it in your Mac. Any card the camera already takes photos on works.")
            Text("Your photos stay on the card. Mark One adds one file, in a folder named DCOLYMP, replacing any older E-M5 firmware there. It reads the file back to check the card, then ejects it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let volume = cards.first {
                HStack {
                    Label(volume.lastPathComponent, systemImage: "sdcard")
                    Spacer()
                    Button("Write to this card") { write(volume) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the card…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cameraSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The card is ready and ejected. Now install from it on the camera.")
            VStack(alignment: .leading, spacing: 10) {
                numbered(1, "Put the card in the camera and unplug the USB cable. Use a fully charged battery, not a dummy battery.")
                numbered(2, "Switch the camera off.")
                numbered(3, "Press and hold OK, the button in the middle of the arrow pad on the back.")
                numbered(4, "Keep holding OK, and switch the camera on. The screen stays dark; that's expected.")
                numbered(5, "When the orange light on the front (the AF-assist light) comes on and stays on, let go of OK.")
                numbered(6, "Wait about a minute while the light stays on. The camera is installing.")
                numbered(7, "When the light starts blinking quickly, it's done. Take the battery out, put it back, and switch the camera on as usual.")
                numbered(8, "Connect the camera to your Mac and choose Webcam on its screen.")
            }
            Label("While the light is on and not blinking, don't switch the camera off, open the battery door or take the card out. The camera is writing its firmware, and stopping it partway can leave it unable to start.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                lightRow(.steady, "On, steady", "Installing. Leave the camera alone until it blinks.")
                lightRow(.blinking, "Blinking quickly", "Done. Take the battery out and put it back.")
                lightRow(.off, "Doesn't come on", "The camera didn't start the installer. Switch it off and start again from step 3.")
                lightRow(.off, "Starts normally", "It missed the card. The firmware is still on it, so try again.")
            }
            .font(.callout)
            Text("Afterwards you can delete the DCOLYMP folder from the card, or leave it: the camera only reads it when you hold OK as you switch it on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Mark One carries on when it sees the camera.").foregroundStyle(.secondary)
            }
        }
    }

    /// Writes the firmware to the card. macOS asks once whether Mark One may
    /// use removable volumes.
    private func write(_ volume: URL) {
        guard let image else { return }
        error = nil
        step = .writing
        Task.detached {
            do {
                try FirmwareInstall.writeToCard(volume, image)
                await MainActor.run { step = .camera }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    step = .card
                }
            }
        }
    }


    private var usb: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let install = pipeline.install {
                if let failure = install.error {
                    Text(failure).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Close") { pipeline.install = nil; step = .start; closeWindow() }
                    }
                } else if install.finished {
                    Label(action == .restore ? "Olympus's firmware is back on the camera" : "Your camera is ready",
                          systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(action == .restore
                         ? "To use the camera with Mark One again, choose Set Up Camera."
                         : pipeline.connectAsWebcam
                         ? "Pick “Mark One” as the camera in any video app."
                         : "Choose Webcam on the camera when you connect it, then pick “Mark One” as the camera in any video app.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Done") { pipeline.install = nil; step = .start; closeWindow() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else if install.phase == .switchOffFirst {
                    Text("Mark One set the camera's USB Mode back to Auto, which Olympus's firmware needs. The camera saves it when it's switched off.")
                        .fixedSize(horizontal: false, vertical: true)
                    numbered(1, "Switch the camera off and on.")
                    numbered(2, "Choose Webcam on its screen. The restore carries on by itself.")
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the camera.").foregroundStyle(.secondary)
                    }
                } else if install.phase == .installing {
                    Text("The camera has the firmware and is installing it.")
                    CameraUpdateScreen().frame(maxWidth: .infinity)
                    numbered(1, "Wait while the camera's screen shows this. If Mark One was using the camera, the screen flickers between this and the last picture. Don't switch the camera off or unplug it.")
                    if install.restarts {
                        numbered(2, "When the screen shows OK, the camera restarts by itself, with the new firmware. It takes about a minute and a half.")
                        numbered(3, action == .restore ? "It asks how to connect again, as it did before Mark One."
                                 : pipeline.connectAsWebcam ? "Mark One connects to it again. There's nothing to do."
                                 : "Choose Webcam on its screen when it asks.")
                    } else {
                        numbered(2, "When the screen shows OK, or goes back to the picture it showed before, the install is done. The camera keeps running the old firmware until it restarts, so switch it off and on.")
                        numbered(3, action == .restore ? "Connect the camera to your Mac again."
                                 : pipeline.connectAsWebcam ? "Connect the camera to your Mac again."
                                 : "Connect the camera to your Mac again and choose Webcam on its screen.")
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Mark One carries on when it sees the camera.").foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView(value: install.fraction) { Text(install.text) }
                    Label("Don't switch off or unplug the camera.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your camera is ready", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("When you connect the camera, choose Webcam on its screen. Then pick “Mark One” as the camera in any video app. Later updates install over USB from this window.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { step = .start; closeWindow() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.headline.monospacedDigit()).frame(width: 16)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row of the orange light's meanings during a card install.
    private func lightRow(_ state: OrangeLight.State, _ light: String, _ meaning: String) -> some View {
        GridRow {
            HStack(spacing: 8) {
                OrangeLight(state: state)
                Text(light).fontWeight(.medium)
            }
            Text(meaning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

/// The camera's orange AF-assist light, as it looks during a card install.
private struct OrangeLight: View {
    enum State { case steady, blinking, off }
    let state: State

    var body: some View {
        if state == .blinking {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.2) % 2 == 0
                dot(lit: on)
            }
        } else {
            dot(lit: state == .steady)
        }
    }

    private func dot(lit: Bool) -> some View {
        Circle()
            .fill(lit ? Color.orange : Color.secondary.opacity(0.3))
            .frame(width: 9, height: 9)
            .shadow(color: lit ? .orange.opacity(0.7) : .clear, radius: 3)
            .accessibilityHidden(true)
    }
}
