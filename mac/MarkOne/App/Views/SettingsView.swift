// Mark One's Settings window.

import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline

    var body: some View {
        TabView {
            GeneralSettings(pipeline: pipeline)
                .tabItem { Label("General", systemImage: "gearshape") }
            CameraSettings(installer: installer, pipeline: pipeline)
                .tabItem { Label("Camera", systemImage: "camera") }
            PictureSettings(pipeline: pipeline)
                .tabItem { Label("Picture", systemImage: "camera.aperture") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var pipeline: Pipeline
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                OpenAtLoginToggle()
                Toggle("Show in the Dock", isOn: $preferences.showInDock)
                Toggle(isOn: $preferences.notifyWhenOff) {
                    Text("Tell me when the camera turns off")
                    if preferences.notificationsDenied {
                        Text("Notifications are off for Mark One. Turn them on in System Settings, under Notifications.")
                    }
                }
            }
            Section("Recording") {
                Picker(selection: $pipeline.grace) {
                    ForEach(Pipeline.Grace.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Stop after the call ends")
                    Text("A short wait lets you switch apps without the camera restarting.")
                }
                Toggle("Mirror the preview", isOn: $preferences.mirrorPreview)
            }
            Section("Camera") {
                Toggle(isOn: $pipeline.connectAsWebcam) {
                    Text("Connect as a webcam without asking")
                    Text("Sets the camera's USB Mode to Webcam. Off puts it back to Auto, so the camera asks how to connect.")
                }
            }
            if Updater.enabled {
                Section {
                    Toggle(isOn: $updater.checksAutomatically) {
                        Text("Check for updates automatically")
                        Text("Once a day, and never during a call.")
                    }
                }
            }
            Section {
                LabeledContent("Setup") {
                    Button("Show Welcome Window…") { WelcomeWindow.show() }
                }
            } footer: {
                Text("Walks through allowing the camera, the firmware and connecting the E-M5 (Mark I).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                Toggle(isOn: $preferences.detailedLogging) {
                    Text("Detailed logging")
                    Text("Logs what Mark One is doing once a minute, for tracking down problems such as the camera not coming back after the Mac sleeps.")
                }
                LabeledContent("Log") {
                    Button("Save Log…") { Diagnostics.saveLog() }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CameraSettings: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("This camera") {
                LabeledContent("Camera", value: "OM-D E-M5 (Mark I)")
                LabeledContent("Firmware") {
                    HStack {
                        Text(pipeline.firmware?.label ?? "Not connected")
                            .fixedSize()
                        Button(pipeline.firmware?.updateAvailable == true ? "Update…" : "Manage…") {
                            openWindow.firmware()
                        }
                    }
                }
                LabeledContent("Video", value: "1080p, 30 fps, H.264")
                if let battery = pipeline.battery {
                    LabeledContent("Battery") { BatteryLevel(level: battery) }
                }
            }
            Section("Mac extension") {
                // One button, for the opposite of the status. Installing again
                // while it's installed does nothing: the installer only
                // replaces the extension with a different version.
                LabeledContent("Status") {
                    HStack {
                        Text(installer.needsReopen ? "Reopen Mark One to use it"
                             : installer.installed ? "Installed" : installer.needsApproval ? "Needs approval" : installer.status)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        if installer.needsReopen {
                            Button("Reopen") { WelcomeWindow.reopen() }
                        } else if installer.installed {
                            Button("Remove…", role: .destructive) { confirmRemove = true }
                        } else if installer.needsApproval {
                            Button("Open System Settings") { ExtensionInstaller.openSystemSettings() }
                        } else {
                            Button("Install") { installer.activate() }
                        }
                    }
                }
            }
            Section {
                Toggle("Lock camera controls", isOn: $pipeline.lockControls)
            } footer: {
                Text("While Mark One uses the camera, only its power switch, dials and shutter half press work, so a bump can’t change a setting or take a photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Link("Firmware guide and help", destination: URL(string: "https://superhighfives.com/mark-one/help")!)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove the Mark One camera?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { installer.deactivate() }
        } message: {
            Text("Video apps stop listing Mark One until you reinstall it.")
        }
    }
}

private struct PictureSettings: View {
    @ObservedObject var pipeline: Pipeline

    var body: some View {
        Form {
            // Brightness, white balance, picture mode and autofocus are in
            // the menu bar panel.
            Section {
                Toggle("Focus on faces", isOn: $pipeline.faceFocus)
                Toggle("Focus when a call starts", isOn: $pipeline.focusOnStart)
                KeyboardShortcuts.Recorder("Focus now", name: .focus)
            } header: {
                Text("Focus")
            } footer: {
                Text("The shortcut works from any app while a video app uses the camera. If Focus is set to Always, it switches to Once first, and the picture pauses for a second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Mode", selection: $pipeline.exposureMode) {
                    ForEach(Pipeline.ExposureMode.allCases) { Text($0.label).tag($0) }
                }
                if pipeline.exposureMode.setsAperture {
                    Picker("Aperture", selection: $pipeline.aperture) {
                        ForEach(Pipeline.Aperture.allCases) { Text($0.label).tag($0) }
                    }
                }
                if pipeline.exposureMode.setsShutter {
                    Picker("Shutter speed", selection: $pipeline.shutterSpeed) {
                        ForEach(Pipeline.ShutterSpeed.allCases) { Text($0.label).tag($0) }
                    }
                }
                if pipeline.exposureMode == .manual {
                    Picker("ISO", selection: $pipeline.iso) {
                        ForEach(Pipeline.ISO.allCases) { Text($0.label).tag($0) }
                    }
                }
                Picker("Stabilization", selection: $pipeline.stabilization) {
                    ForEach(Pipeline.Stabilization.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Exposure")
            } footer: {
                Text("A low f-number blurs the background. 1/50 or 1/100 s stops lights flickering on 50 Hz power, 1/60 or 1/125 s on 60 Hz. In Shutter priority the camera keeps the brightness the same; Manual sets it. Changes during a call pause the picture for about 5 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AboutSettings: View {
    @ObservedObject private var updater = Updater.shared
    @State private var showLicense = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text("Mark One").font(.title2.weight(.bold))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if Updater.enabled {
                    Button("Check for Updates…") { updater.check() }
                        .disabled(!updater.canCheck)
                }
                // Mark One is free; this is the tip jar.
                Link("Support My Work…", destination: URL(string: "https://github.com/sponsors/superhighfives")!)
            }
            Form {
                Section("Acknowledgements") {
                    LabeledContent {
                        HStack(spacing: 12) {
                            Link("Source", destination: URL(string: "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz")!)
                            Button("License") { showLicense = true }
                                .buttonStyle(.link)
                        }
                    } label: {
                        Text("FFmpeg 9.0.2 (libavcodec, libavutil)")
                        Text("Decodes the camera’s video on older Mark One firmware, and if Apple’s decoder can’t. LGPL 2.1, built from the unmodified source and shipped as separate libraries.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 130)
            Text("Made by Charlie Gleason. Olympus and OM-D are trademarks of OM Digital Solutions. Mark One isn’t affiliated with or endorsed by them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 20)
        .sheet(isPresented: $showLicense) { LicenseSheet() }
    }
}

/// FFmpeg's license, from the copy that ships in the app.
private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Bundle.main.url(forResource: "COPYING", withExtension: "LGPLv2.1")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The license text is missing from this copy of Mark One."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GNU Lesser General Public License, version 2.1").font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
