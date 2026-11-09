// Mark One's Settings window.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            CameraSettings(installer: installer, pipeline: pipeline)
                .tabItem { Label("Camera", systemImage: "camera") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var planned = Planned.shared

    var body: some View {
        Form {
            Section {
                OpenAtLoginToggle()
                Toggle("Show in the Dock", isOn: $planned.showInDock)
                Toggle("Tell me when the camera turns off", isOn: $planned.notifyWhenOff)
            }
            Section("Recording") {
                Picker(selection: $planned.grace) {
                    ForEach(Planned.Grace.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Stop after the call ends")
                    Text("A short wait lets you switch apps without the camera restarting.")
                }
                Toggle("Mirror the preview", isOn: $planned.mirrorPreview)
            }
            Section {
                LabeledContent("Setup") {
                    Button("Show Welcome Window…") { WelcomeWindow.show() }
                }
            } footer: {
                Text("Walks through allowing the camera, the firmware and connecting the E-M5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CameraSettings: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var pipeline: Pipeline
    @ObservedObject private var planned = Planned.shared
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("This camera") {
                LabeledContent("Camera", value: "OM-D E-M5")
                LabeledContent("Firmware", value: planned.firmware)
                LabeledContent("Video", value: "1080p, 30 fps, H.264")
                if let battery = planned.battery {
                    LabeledContent("Battery") { BatteryLevel(level: battery) }
                }
            }
            Section("Picture") {
                BrightnessControl(pipeline: pipeline)
                Picker("White balance", selection: $planned.whiteBalance) {
                    ForEach(Planned.WhiteBalance.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Picture mode", selection: $planned.pictureMode) {
                    ForEach(Planned.PictureMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Continuous autofocus", isOn: $pipeline.continuousFocus)
                Toggle("Focus on faces", isOn: $planned.faceFocus)
            }
            Section {
                Toggle("Lock camera controls", isOn: $pipeline.lockControls)
            } footer: {
                Text("While Mark One uses the camera, only its power switch, dials and shutter half press work, so a bump can’t change a setting or take a photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Mark One camera") {
                LabeledContent("Status", value: installer.installed ? "Installed and allowed" : installer.status)
                HStack {
                    Spacer()
                    if installer.needsApproval {
                        Button("Open System Settings") { ExtensionInstaller.openSystemSettings() }
                    }
                    Button("Reinstall") { installer.activate() }
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
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

private struct AboutSettings: View {
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
            Form {
                Section("Acknowledgements") {
                    LabeledContent {
                        HStack(spacing: 12) {
                            Link("Source", destination: URL(string: "https://ffmpeg.org/download.html")!)
                            Link("Licence", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!)
                        }
                    } label: {
                        Text("FFmpeg (libavcodec)")
                        Text("Decodes the camera’s video. LGPL 2.1, shipped unmodified.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 110)
            Text("Made by Charlie Gleason. Olympus and OM-D are trademarks of OM Digital Solutions. Mark One isn’t affiliated with or endorsed by them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 20)
    }
}
