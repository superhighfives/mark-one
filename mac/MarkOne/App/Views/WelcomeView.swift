// The welcome window: allow the camera, put the firmware on the E-M5,
// connect it. It opens on first launch, from Settings, and when Mark One
// finds a camera without the right firmware.

import AppKit
import SwiftUI

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    private static let shownKey = "WelcomeShown"

    /// Whether the welcome window hasn't been finished yet.
    static var needed: Bool { !UserDefaults.standard.bool(forKey: shownKey) }

    static func show(at step: WelcomeView.Step = .welcome) {
        let window = window ?? {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = "Welcome to Mark One"
            Self.window = window
            return window
        }()
        let host = NSHostingController(rootView: WelcomeView(start: step, done: finish))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: shownKey)
        window?.close()
    }
}

struct WelcomeView: View {
    enum Step: Int, CaseIterable {
        case welcome, allow, firmware, connect, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .allow: "Allow the camera"
            case .firmware: "Firmware"
            case .connect: "Connect"
            case .done: "Done"
            }
        }
    }

    @State private var step: Step
    let done: () -> Void
    @ObservedObject private var installer = ExtensionInstaller.shared
    @ObservedObject private var pipeline = Pipeline.shared
    @Environment(\.openWindow) private var openWindow

    private var connectedDetail: String {
        var parts = [pipeline.firmware.map { "Firmware: \($0.label)" } ?? "Checking the firmware…"]
        if let battery = pipeline.battery { parts.append("Battery \(CameraBattery(level: battery).label.lowercased())") }
        return parts.joined(separator: " · ")
    }

    init(start: Step = .welcome, done: @escaping () -> Void) {
        _step = State(initialValue: start)
        self.done = done
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                buttons
                    .padding(.top, 14)
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 18)
        }
        .frame(width: 720, height: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Step.allCases, id: \.self) { item in
                let done = item.rawValue < step.rawValue
                let current = item == step
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .strokeBorder(current || done ? Color.primary : Color.secondary, lineWidth: 1)
                            .background(Circle().fill(current || done ? Color.primary : .clear))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        } else {
                            Text("\(item.rawValue + 1)").font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(current || done ? Color(nsColor: .windowBackgroundColor) : .secondary)
                    .frame(width: 20, height: 20)
                    Text(item.title)
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(item.rawValue > step.rawValue ? .secondary : .primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(current ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .allow: allow
        case .firmware: firmware
        case .connect: connect
        case .done: finished
        }
    }

    private var buttons: some View {
        HStack {
            Button("Back") { move(-1) }
                .disabled(step == .welcome)
            Spacer()
            Button(nextTitle) { step == .done ? done() : move(1) }
                .primary(step != .firmware || installed)
        }
        .controlSize(.large)
    }

    /// Whether the camera reports Mark One's firmware. Until it does, the
    /// firmware step's main action is Set Up Camera, not It's Installed.
    private var installed: Bool {
        if case .markOne = pipeline.firmware { return true }
        return false
    }

    private var nextTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .firmware: "It’s Installed"
        case .done: "Done"
        default: "Continue"
        }
    }

    private func move(_ by: Int) {
        if let next = Step(rawValue: step.rawValue + by) { step = next }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Your E-M5 (Mark I), on every call")
                .font(.largeTitle.weight(.bold))
            Text("Mark One turns an OM-D E-M5 (Mark I) into a webcam over one USB cable, with the camera’s own lens, sensor and colour. Setup takes three steps, and you only do it once.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var allow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow the Mark One camera").font(.title.weight(.bold))
            Text("macOS asks before an app adds a camera. Open System Settings, go to **General › Login Items & Extensions › Camera Extensions**, and turn on Mark One.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card(padding: 14) {
                HStack(spacing: 12) {
                    if installer.installed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Camera allowed").fontWeight(.semibold)
                            Text("“Mark One” now shows up in video apps.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else if installer.failed {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text(installer.status).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Again") { installer.activate() }
                    } else {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading) {
                            Text("Waiting for your OK").fontWeight(.semibold)
                            Text("This moves on by itself once you allow it.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open System Settings") { ExtensionInstaller.openSystemSettings() }
                    }
                }
            }
        }
    }

    private var firmware: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Put the Mark One firmware on the camera").font(.title.weight(.bold))
            Text("Mark One needs Olympus’s firmware 2.3 with a few changes that let the camera send video. It builds the firmware for you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install it once from an SD card").fontWeight(.semibold)
                    Text("About 10 minutes. Later updates install over USB.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Camera…") { openWindow.firmware() }
                        .primary(!installed)
                        .fixedSize()
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label {
                Text("Use a full battery, and don’t switch the camera off while it updates. You can go back to Olympus’s firmware the same way.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").frame(width: 18)
            }
                .font(.callout)
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect the camera").font(.title.weight(.bold))
            Text("Plug the camera in, switch it on and choose **Webcam** on its screen.")
                .foregroundStyle(.secondary)
            Card(padding: 14) {
                HStack(spacing: 14) {
                    CameraSketch(lit: pipeline.state == .streaming)
                        .frame(width: 72, height: 48)
                    if pipeline.firmware == .stock || pipeline.problem == .wrongFirmware {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This camera needs the Mark One firmware").fontWeight(.semibold)
                            Text(pipeline.status).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Set Up Camera…") { openWindow.firmware() }
                    } else if pipeline.state != .waiting {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("E-M5 (Mark I) connected").fontWeight(.semibold)
                            Text(connectedDetail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Looking for the camera…").fontWeight(.semibold)
                            Text(pipeline.status).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Text("The E-M5 (Mark I) runs on its battery, even over USB. For long calls, a dummy battery with a power adapter keeps it going.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You’re all set").font(.largeTitle.weight(.bold))
            Text("Open FaceTime, Zoom or any video app and choose **Mark One** as the camera. Mark One starts the camera when a call starts and stops it when the call ends. It lives in the menu bar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    OpenAtLoginToggle()
                    Text("So the camera is ready whenever you plug it in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
    }
}

private extension View {
    /// The blue default button when `on`, a plain one otherwise.
    @ViewBuilder func primary(_ on: Bool) -> some View {
        if on {
            buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            buttonStyle(.bordered)
        }
    }
}
