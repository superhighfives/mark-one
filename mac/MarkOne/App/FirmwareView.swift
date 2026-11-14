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
    /// After a restore, whether the camera has had time to install and
    /// restart, so the window can be closed without waiting for MTP.
    @State private var restoreSettled = false

    /// Opens on the first step; previews can start at any.
    init(pipeline: Pipeline, start: Step = .start, action: Action = .setUp, cards: [URL] = []) {
        _pipeline = ObservedObject(wrappedValue: pipeline)
        _step = State(initialValue: start)
        _action = State(initialValue: action)
        _cards = State(initialValue: cards)
    }

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
        // Steps narrower than the window start at its left edge.
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Setting up from the card starts at its confirmation.
            if overUSB {
                manage
            } else {
                confirm.onAppear {
                    if action != .setUp { action = .setUp; understood = false }
                }
            }
        case .ready: ready
        case .confirm: confirm
        case .preparing: preparing
        case .card: card
        case .writing:
            // As tall as the card step before it, so the window keeps its size.
            card.hidden().disabled(true).overlay {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Writing to the card…").foregroundStyle(.secondary)
                }
            }
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
            footer {
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
                steps {
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
            footer {
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

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action {
            case .setUp:
                Text("Mark One adds a Webcam choice to your camera. Everything else works just as before.")
                    .fixedSize(horizontal: false, vertical: true)
            case .update:
                lead("arrow.down.circle") {
                    Text("Mark One sends its firmware to the camera over USB. It takes about two minutes. [How updates work](https://superhighfives.com/mark-one/help#updates)")
                }
            case .restore:
                lead("arrow.uturn.backward.circle") {
                    Text("Mark One puts Olympus's firmware 2.3 back on the camera over USB. [How going back works](https://superhighfives.com/mark-one/help#going-back)")
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Before you install", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                    point("battery.100percent", "Use a charged battery.")
                    point("hand.raised", "Leave the camera alone until it's done. If it loses power partway, it may not start again.")
                    if action != .restore {
                        point("checkmark.shield", "This firmware is unofficial, and not supported by Olympus or OM System.")
                    }
                }
                .padding(8)
            }
            Toggle(isOn: $understood) {
                Text("I understand, and I accept the risk").padding(.leading, 4)
            }
            if lowBattery {
                Label("The camera's battery is low. Charge it before installing.", systemImage: "battery.25percent")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Like the welcome window's buttons.
            Divider().padding(.top, 8)
            HStack {
                Button("Cancel") {
                    // Setting up from the card has no step before this one.
                    if action == .setUp && !overUSB { closeWindow() } else { step = .start }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action == .setUp ? "Continue" : action == .restore ? "Restore" : "Install") { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood || lowBattery)
            }
            .controlSize(.large)
            .padding(.top, 2)
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
            lead("sdcard") {
                Text("Take the SD card out of your camera and put it in your Mac. Any card the camera already takes photos on works.")
            }
            Text("Your photos stay on the card. Mark One adds one file, in a folder named DCOLYMP, replacing any older E-M5 firmware there. It reads the file back to check the card, then ejects it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 4)
            // Both rows take the same space, so the window keeps its size
            // when the card shows up.
            ZStack(alignment: .leading) {
                HStack {
                    Label(cards.first?.lastPathComponent ?? "", systemImage: "sdcard")
                    Spacer()
                    Button("Write to this card") { if let volume = cards.first { write(volume) } }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .opacity(cards.isEmpty ? 0 : 1)
                .disabled(cards.isEmpty)
                .accessibilityHidden(cards.isEmpty)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the card…").foregroundStyle(.secondary)
                }
                .opacity(cards.isEmpty ? 1 : 0)
                .accessibilityHidden(!cards.isEmpty)
            }
        }
    }

    private var cameraSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            lead("camera") {
                Text("The card is ready. Now install from it on the camera. [Full steps and troubleshooting](https://superhighfives.com/mark-one/help#installing-it-from-the-card)")
            }
            steps {
                numbered(1, "Put the card in the camera, unplug the USB cable and switch the camera off. Use a charged battery.")
                numbered(2, "Hold OK and switch the camera on. Let go when the orange light on the front comes on.")
                numbered(3, "Wait about a minute, until the light blinks quickly. Then switch the camera off.")
                numbered(4, "Switch the camera on and connect it to your Mac. If it asks how to connect, choose Webcam.")
            }
            CardInstallSequence()
            Label("While the light is on, don't switch the camera off, open the battery door or take the card out.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 4)
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
                    footer {
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
                    footer {
                        Button("Done") { pipeline.install = nil; step = .start; closeWindow() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else if install.phase == .switchOffFirst {
                    lead("power") {
                        Text("Mark One set the camera's USB Mode back to Auto, which Olympus's firmware needs. The camera saves it when it's switched off.")
                    }
                    steps {
                        numbered(1, "Switch the camera off and on.")
                        numbered(2, "Choose Webcam on its screen. The restore carries on by itself.", choose: .webcam)
                    }
                    Divider().padding(.top, 4)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the camera.").foregroundStyle(.secondary)
                    }
                } else if install.phase == .installing {
                    Text("The camera has the firmware and is installing it.")
                    CameraUpdateScreen().frame(maxWidth: .infinity)
                    steps {
                        numbered(1, "Wait while the camera's screen shows this. If Mark One was using the camera, the screen flickers between this and the last picture. Don't switch the camera off or unplug it.")
                        if install.restarts {
                            numbered(2, "When the screen shows OK, the camera restarts by itself, with the new firmware. It takes about a minute and a half.")
                            numbered(3, action == .restore ? "It asks how to connect again, as it did before Mark One. Choose MTP, so Mark One can check the firmware."
                                     : pipeline.connectAsWebcam ? "Mark One connects to it again. There's nothing to do."
                                     : "Choose Webcam on its screen when it asks.",
                                     choose: action == .restore ? .mtp : pipeline.connectAsWebcam ? nil : .webcam)
                        } else {
                            numbered(2, "When the screen shows OK, or goes back to the picture it showed before, the install is done. The camera keeps running the old firmware until it restarts, so switch it off and on.")
                            numbered(3, action == .restore ? "Connect the camera to your Mac again and choose MTP on its screen, so Mark One can check the firmware."
                                     : pipeline.connectAsWebcam ? "Connect the camera to your Mac again."
                                     : "Connect the camera to your Mac again and choose Webcam on its screen.",
                                     choose: action == .restore ? .mtp : pipeline.connectAsWebcam ? nil : .webcam)
                        }
                    }
                    Divider().padding(.top, 4)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(action == .restore ? "Waiting for the camera to connect as MTP." : "Mark One carries on when it sees the camera.")
                            .foregroundStyle(.secondary)
                        // Olympus's firmware asks how to connect, and only MTP
                        // lets Mark One check it. Once the camera has had time
                        // to restart, the restore can end without that.
                        if action == .restore && restoreSettled {
                            Spacer()
                            Button("Done") { pipeline.install = nil; step = .start; closeWindow() }
                        }
                    }
                    .task {
                        restoreSettled = false
                        guard (try? await Task.sleep(for: .seconds(120))) != nil else { return }
                        restoreSettled = true
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
            footer {
                Button("Done") { step = .start; closeWindow() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The last row of a step: a divider, then its button on the right, as
    /// in the welcome window.
    private func footer(@ViewBuilder _ button: () -> some View) -> some View {
        VStack(spacing: 14) {
            Divider()
            HStack {
                Spacer()
                button()
            }
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    /// A step's main line, with a large symbol beside it.
    private func lead(_ symbol: String, @ViewBuilder _ text: () -> Text) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 32)
            text().fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line of a list, with a symbol.
    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }

    /// Numbered steps, in a box.
    private func steps(@ViewBuilder _ content: () -> some View) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private func numbered(_ n: Int, _ text: String, choose: CameraUSBMenu.Choice? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.headline.monospacedDigit()).frame(width: 16)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let choose { CameraUSBMenu(choose: choose) }
            }
        }
    }


    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

/// The camera's orange light during a card install: on while it installs,
/// then blinking when it's done.
private struct CardInstallSequence: View {
    var body: some View {
        HStack(spacing: 6) {
            stage("Installing") { OrangeLight(state: .steady, size: 18) }
            arrow
            stage("Done") { OrangeLight(state: .blinking, size: 18) }
        }
        .frame(maxWidth: .infinity)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func stage(_ caption: String, @ViewBuilder _ light: () -> some View) -> some View {
        VStack(spacing: 10) {
            light()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(Color(white: 0.043), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

/// The camera's orange AF-assist light, as it looks during a card install.
private struct OrangeLight: View {
    enum State { case steady, blinking, off }
    let state: State
    var size: CGFloat = 9

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
            .frame(width: size, height: size)
            .shadow(color: lit ? .orange.opacity(0.7) : .clear, radius: size / 3)
            .accessibilityHidden(true)
    }
}

// Open this file in Xcode to see each step in the canvas, with no camera.
#Preview("Set up") {
    FirmwareView(pipeline: .shared)
}

#Preview("Getting the firmware") {
    FirmwareView(pipeline: .shared, start: .preparing)
}

#Preview("Waiting for the card") {
    FirmwareView(pipeline: .shared, start: .card)
}

#Preview("Writing to the card") {
    FirmwareView(pipeline: .shared, start: .writing)
}

#Preview("Install from the card") {
    FirmwareView(pipeline: .shared, start: .camera)
}

#Preview("Ready") {
    FirmwareView(pipeline: .shared, start: .ready)
}

#Preview("Camera installing over USB") {
    let pipeline = Pipeline.shared
    pipeline.install = .init(text: "", fraction: 0.5, phase: .installing, restarts: true)
    return FirmwareView(pipeline: pipeline, start: .usb, action: .update)
}
