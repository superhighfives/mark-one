// The Camera Firmware window: puts Mark One's firmware on the camera, from
// the SD card the first time and over USB after that.

import Combine
import SwiftUI

struct FirmwareView: View {
    @ObservedObject var pipeline: Pipeline
    @State private var step = Step.intro
    @State private var understood = false
    @State private var image: FirmwareImage?
    @State private var downloaded = 0.0
    @State private var cards: [URL] = []
    @State private var error: String?

    enum Step { case intro, preparing, card, writing, camera, usb }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Whether this camera takes updates over USB, so the card isn't needed.
    private var overUSB: Bool { pipeline.firmware.map(Firmware.canUpdateOverUSB) ?? false }
    private var upToDate: Bool {
        if case .markOne(let revision) = pipeline.firmware { return revision >= FirmwareImage.bundledRevision }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(overUSB ? "Update your camera" : "Set up your camera")
                .font(.title2.bold())
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
    }

    @ViewBuilder private var content: some View {
        if upToDate && step != .usb {
            done
        } else {
            switch step {
            case .intro: intro
            case .preparing: preparing
            case .card: card
            case .writing: ProgressView("Writing to the card…")
            case .camera: cameraSteps
            case .usb: usb
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(overUSB
                 ? "A newer version of Mark One's camera firmware is ready. Mark One sends it to the camera over USB, and the camera installs it."
                 : "Mark One needs its own firmware on your E-M5. It's Olympus's firmware 2.3 with a few changes that let the camera work as a webcam. Mark One downloads Olympus's firmware, adds its changes, and puts the result on your SD card. You install it from the card once; later updates happen over USB.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Installing firmware has a risk", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("This is unofficial firmware, not made or supported by Olympus or OM System. If the camera loses power or is disconnected while it installs, it may not turn on again, and you could lose the camera. A charged battery and an undisturbed camera make that very unlikely, and so far Olympus's own firmware has always gone back on from the card. Only continue if you accept the risk.")
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I understand, and I accept the risk", isOn: $understood)
                }
                .padding(4)
            }
            HStack {
                Spacer()
                Button(overUSB ? "Update camera" : "Continue") { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood)
            }
        }
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: downloaded) { Text("Downloading Olympus's firmware…") }
            Text("About 47 MB, from Olympus's update server.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("The card is ready and ejected. Now, on the camera:")
            VStack(alignment: .leading, spacing: 8) {
                numbered(1, "Put the card in the camera. Unplug the USB cable, and check that the battery is charged.")
                numbered(2, "Hold down OK and switch the camera on. The screen stays dark. Let go of OK when the orange light on the front comes on.")
                numbered(3, "Wait. The light stays on for about a minute while the camera installs. Don't switch it off or open the battery door.")
                numbered(4, "When the light starts blinking, the camera is done. Take the battery out, put it back, and switch the camera on.")
                numbered(5, "Connect the camera to your Mac and choose Webcam on its screen.")
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Mark One carries on when it sees the camera.").foregroundStyle(.secondary)
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
                        Button("Close") { pipeline.install = nil; step = .intro; closeWindow() }
                    }
                } else if install.finished {
                    done
                } else {
                    ProgressView(value: install.fraction) { Text(install.text) }
                    Label("Don't switch off or unplug the camera.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your camera is ready", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("When you connect the camera, choose Webcam on its screen. Then pick “Mark One” as the camera in any video app.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { pipeline.install = nil; step = .intro; closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.headline.monospacedDigit()).frame(width: 16)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prepare() {
        error = nil
        step = .preparing
        Task {
            do {
                let built = try await FirmwareImage.make { fraction in
                    Task { @MainActor in downloaded = fraction }
                }
                image = built
                if overUSB {
                    step = .usb
                    pipeline.installOverUSB(built)
                } else {
                    cards = FirmwareInstall.cards()
                    step = .card
                }
            } catch {
                self.error = error.localizedDescription
                step = .intro
            }
        }
    }

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

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
