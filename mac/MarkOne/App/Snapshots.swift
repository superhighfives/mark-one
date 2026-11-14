// Debug builds only: draws each step of the Camera Firmware window to PNGs,
// with no camera or card. Run the app with --snapshot-firmware <folder>.

#if DEBUG
import SwiftUI

@MainActor
enum Snapshots {
    static func takeIfAsked() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-firmware"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipeline = Pipeline.shared
        let card = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        let usb = Pipeline.InstallProgress(text: "Sending the firmware to the camera…", fraction: 0.4)
        let shots: [(String, Pipeline.InstallProgress?, FirmwareView)] = [
            ("01-set-up", nil, FirmwareView(pipeline: pipeline)),
            ("02-getting-the-firmware", nil, FirmwareView(pipeline: pipeline, start: .preparing)),
            ("03-waiting-for-the-card", nil, FirmwareView(pipeline: pipeline, start: .card)),
            ("04-card-found", nil, FirmwareView(pipeline: pipeline, start: .card, cards: [card])),
            ("05-writing-to-the-card", nil, FirmwareView(pipeline: pipeline, start: .writing)),
            ("06-install-from-the-card", nil, FirmwareView(pipeline: pipeline, start: .camera)),
            ("07-ready", nil, FirmwareView(pipeline: pipeline, start: .ready)),
            ("08-update-sending", usb, FirmwareView(pipeline: pipeline, start: .usb, action: .update)),
            ("09-update-installing", .init(text: "", fraction: 1, phase: .installing, restarts: true),
             FirmwareView(pipeline: pipeline, start: .usb, action: .update)),
            ("10-update-done", .init(text: "", fraction: 1, finished: true),
             FirmwareView(pipeline: pipeline, start: .usb, action: .update)),
            ("11-restore-switch-off-first", .init(text: "", fraction: 0, phase: .switchOffFirst),
             FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
            ("12-restore-sending", usb, FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
            ("13-restore-installing", .init(text: "", fraction: 1, phase: .installing, restarts: true),
             FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
            ("14-restore-done", .init(text: "", fraction: 1, finished: true),
             FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
        ]
        for (name, install, view) in shots {
            pipeline.install = install
            save(view, to: folder.appendingPathComponent("\(name).png"))
        }
        exit(0)
    }

    /// Shows the step in a window of its own and captures that window, so
    /// it looks as it does in the app, title bar and all.
    private static func save(_ view: FirmwareView, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Camera Firmware"
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        try? capture.run()
        capture.waitUntilExit()
        window.orderOut(nil)
    }
}
#endif
