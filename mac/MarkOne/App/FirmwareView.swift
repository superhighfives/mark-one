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
            Label(current >= bundled ? "Mark One's firmware, up to date (revision \(current))"
                                     : "Mark One's firmware, revision \(current). Revision \(bundled) is ready.",
                  systemImage: current >= bundled ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(current >= bundled ? .green : .accentColor)
                .fixedSize(horizontal: false, vertical: true)
            choice(current < bundled ? "Update" : "Reinstall",
                   current < bundled ? "Install revision \(bundled) over USB."
                                     : "Install the same firmware again over USB, if something seems wrong.") {
                begin(.update)
            }
            choice("Restore Olympus's firmware",
                   "Put Olympus's own firmware 2.3 back over USB. Mark One stops working with the camera until you set it up again.") {
                begin(.restore)
            }
            choice("Prepare for OM Workspace",
                   "Make the camera report firmware 1.0 until it's switched off, so Olympus's OM Workspace offers to install 2.3. Changes nothing permanent.") {
                pipeline.reportOlderVersion()
                step = .omWorkspace
            }
            HStack {
                Spacer()
                Button("Close") { closeWindow() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func choice(_ title: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(title, action: action).labelsHidden()
        }
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
                Text("Mark One sends its firmware to the camera over USB, and the camera checks it and installs it. It takes about two minutes.")
                    .fixedSize(horizontal: false, vertical: true)
            case .restore:
                Text("Mark One downloads Olympus's firmware 2.3 and sends it to the camera over USB, unchanged. Afterward the camera is as it came from Olympus, and Mark One can set it up again from the card.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Installing firmware has a risk", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(action == .restore
                         ? "If the camera loses power or is disconnected while it installs, it may not turn on again, and you could lose the camera. Use a charged battery and leave the camera alone until it's done."
                         : "This is unofficial firmware, not made or supported by Olympus or OM System. If the camera loses power or is disconnected while it installs, it may not turn on again, and you could lose the camera. Use a charged battery and leave the camera alone until it's done. Only continue if you accept the risk.")
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I understand, and I accept the risk", isOn: $understood)
                }
                .padding(4)
            }
            HStack {
                Button("Cancel") { step = .start }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action == .setUp ? "Continue" : action == .restore ? "Restore" : "Install") { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood)
            }
        }
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
            Text("Take the SD card out of your camera and put it in your Mac.")
            Text("Your photos stay on the card. Mark One adds one file, in a folder named DCOLYMP.")
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
                numbered(1, "Put the card in the camera and unplug the USB cable. Check that the battery is charged.")
                numbered(2, "Switch the camera off.")
                numbered(3, "Press and hold OK, the button in the middle of the arrow pad on the back.")
                numbered(4, "Keep holding OK, and switch the camera on. The screen stays dark; that's expected.")
                numbered(5, "When the orange light on the front comes on, let go of OK.")
                numbered(6, "Wait about a minute while the light stays on. The camera is installing, so don't switch it off or open the battery door.")
                numbered(7, "When the light starts blinking, it's done. Take the battery out, put it back, and switch the camera on as usual.")
                numbered(8, "Connect the camera to your Mac and choose Webcam on its screen.")
            }
            Text("If the light doesn't come on, switch the camera off and start again from step 3. If the camera starts normally instead, it missed the card; the firmware is still on it, so just try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Mark One carries on when it sees the camera.").foregroundStyle(.secondary)
            }
        }
    }

    /// Asks for the card in an open panel: the sandbox only lets Mark One
    /// write to a volume the user picks.
    private func write(_ volume: URL) {
        guard let image else { return }
        let panel = NSOpenPanel()
        panel.message = "Mark One needs your permission to write to the card. Choose the card, then click Use This Card."
        panel.prompt = "Use This Card"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = volume
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // Access covers the folder chosen, so it has to be the card itself.
        guard chosen.standardizedFileURL.path == volume.standardizedFileURL.path else {
            error = "Choose the card itself, \(volume.lastPathComponent), not a folder on it or another drive."
            return
        }
        error = nil
        step = .writing
        Task.detached {
            let access = chosen.startAccessingSecurityScopedResource()
            defer { if access { chosen.stopAccessingSecurityScopedResource() } }
            do {
                try FirmwareInstall.writeToCard(chosen, image)
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
                         : "Choose Webcam on the camera when you connect it, then pick “Mark One” as the camera in any video app.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Done") { pipeline.install = nil; step = .start; closeWindow() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else if install.phase == .restartFirst {
                    Text("Mark One was using the camera, so the install starts fresh.")
                    numbered(1, "Check that the battery is charged.")
                    numbered(2, "Switch the camera off and on again, and choose MTP or Webcam on its screen.")
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("The install starts as soon as the camera reconnects.").foregroundStyle(.secondary)
                    }
                } else if install.phase == .installing {
                    Text("The camera has the firmware and is installing it.")
                    numbered(1, "Wait. The camera's screen shows an update animation. Don't switch it off or unplug it.")
                    numbered(2, "When the screen shows OK, the install is done. Switch the camera off and on.")
                    numbered(3, action == .restore ? "Connect the camera to your Mac again."
                                                   : "Connect the camera to your Mac again and choose Webcam on its screen.")
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

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
