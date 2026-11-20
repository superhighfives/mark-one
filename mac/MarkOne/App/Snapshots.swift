// Debug builds only: screenshots every window of the app, in each state,
// with a made-up camera. scripts/snapshot-app.sh runs it, with
// --snapshots <folder>. Nothing is installed or looked for while it runs.

#if DEBUG
import SwiftUI

@MainActor
enum Snapshots {
    /// Where the screenshots go, when the app was opened to take them.
    static let folder: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()

    static var taking: Bool { folder != nil }

    private static let pipeline = Pipeline.shared
    private static let installer = ExtensionInstaller.shared
    private static let latest = CameraFirmware.markOne(FirmwareImage.bundledRevision)

    /// Takes them all, then quits. `openSettings` comes from the menu bar
    /// icon, which is always there.
    static func run(openSettings: OpenSettingsAction) {
        guard let folder, !started else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            await welcome(folder.appendingPathComponent("welcome"))
            await panel(folder.appendingPathComponent("panel"))
            await settings(folder.appendingPathComponent("settings"), openSettings: openSettings)
            await firmware(folder.appendingPathComponent("firmware"))
            exit(failed ? 1 : 0)
        }
    }

    private static var started = false
    /// Whether any screenshot couldn't be taken, such as while the screen
    /// is locked.
    private static var failed = false

    // MARK: Windows

    private static func welcome(_ folder: URL) async {
        let shots: [(String, WelcomeView.Step, () -> Void)] = [
            ("01-welcome", .welcome, {}),
            ("02-allow-checking", .allow, { allow(checked: false) }),
            ("03-allow-steps", .allow, { allow(needsApproval: true) }),
            ("04-allow-allowed", .allow, { allow(installed: true) }),
            ("05-allow-allowed-reopen", .allow, { allow(installed: true, needsReopen: true) }),
            ("06-allow-restart", .allow, { allow(failed: true, needsRestart: true, status: restartStatus) }),
            ("07-allow-move-to-applications", .allow, { allow(failed: true, notInApplications: true, status: applicationsStatus) }),
            ("08-firmware", .firmware, { allow(installed: true); pipeline.pretend(status: waitingStatus) }),
            ("09-firmware-installed", .firmware, { pipeline.pretend(.ready, status: readyStatus, firmware: latest, battery: 100) }),
            ("10-connect-looking", .connect, { pipeline.pretend(status: waitingStatus) }),
            ("11-connect-needs-firmware", .connect, { pipeline.pretend(status: stockStatus, problem: .wrongFirmware, firmware: .stock) }),
            ("12-connect-connected", .connect, { pipeline.pretend(.ready, status: readyStatus, firmware: latest, battery: 100) }),
            ("13-done", .done, {}),
        ]
        for (name, step, setUp) in shots {
            setUp()
            WelcomeWindow.show(at: step)
            await capture(NSApp.windows.first { $0.title == "Welcome to Mark One" }, to: folder, name)
        }
        // Hidden rather than closed: closing it would start setup.
        NSApp.windows.first { $0.title == "Welcome to Mark One" }?.orderOut(nil)
    }

    private static func panel(_ folder: URL) async {
        let sending = Pipeline.InstallProgress(text: "Sending the firmware to the camera…", fraction: 0.4)
        let shots: [(String, () -> Void)] = [
            ("01-allow", { allow(needsApproval: true); pipeline.pretend(status: waitingStatus) }),
            ("02-restart", { allow(failed: true, needsRestart: true, status: restartStatus) }),
            ("03-move-to-applications", { allow(failed: true, notInApplications: true, status: applicationsStatus) }),
            ("04-looking", { allow(installed: true); pipeline.pretend(status: waitingStatus) }),
            ("05-camera-off", { pipeline.pretend(status: waitingStatus, problem: .cameraOff, firmware: latest) }),
            ("06-connected-for-photos", { pipeline.pretend(status: photosStatus, problem: .connectedForPhotos, firmware: latest) }),
            ("07-no-card", { pipeline.pretend(status: noCardStatus, problem: .noCard, firmware: .markOne(0)) }),
            ("08-needs-firmware", { pipeline.pretend(status: stockStatus, problem: .wrongFirmware, firmware: .stock, battery: 100) }),
            ("09-updating", { pipeline.pretend(status: "Installing Mark One's firmware…", firmware: latest, install: sending) }),
            ("10-ready", { pipeline.pretend(.ready, status: readyStatus, firmware: latest, battery: 100) }),
            ("11-in-a-call", { pipeline.pretend(.streaming, status: "Recording", firmware: latest, battery: 100,
                                                framesPerSecond: 30, activeApp: "FaceTime") }),
            ("12-low-battery-and-update", { pipeline.pretend(.ready, status: readyStatus, firmware: .markOne(FirmwareImage.bundledRevision - 1), battery: 50) }),
            ("13-needs-restarting", { allow(installed: true, needsReopen: true); pipeline.pretend(status: "Waiting for the Mark One camera to start…") }),
        ]
        // The first panel shown draws its blue button grey, as if inactive,
        // so one is shown and thrown away first.
        allow(needsApproval: true)
        let first = panelWindow()
        try? await Task.sleep(for: .seconds(1))
        first.orderOut(nil)
        for (name, setUp) in shots {
            setUp()
            let panel = panelWindow()
            await capture(panel, to: folder, name)
            panel.orderOut(nil)
        }
    }

    private static func settings(_ folder: URL, openSettings: OpenSettingsAction) async {
        let shots: [(String, Int, () -> Void)] = [
            ("01-general", 0, { allow(installed: true); pipeline.pretend(.ready, status: readyStatus, firmware: latest, battery: 100) }),
            ("02-camera", 1, {}),
            ("03-camera-update", 1, { pipeline.pretend(.ready, status: readyStatus, firmware: .markOne(FirmwareImage.bundledRevision - 1), battery: 50) }),
            ("04-camera-not-set-up", 1, { allow(needsApproval: true); pipeline.pretend(status: waitingStatus) }),
            ("05-picture", 2, {}),
            ("06-about", 3, {}),
        ]
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(0.5))
        // It takes a moment to open.
        var window: NSWindow?
        for _ in 0..<30 where window == nil {
            // Titled after the tab it opens on: the last one shown.
            window = NSApp.windows.first { $0.isVisible && ["General", "Camera", "Picture", "About"].contains($0.title) }
            if window == nil { try? await Task.sleep(for: .seconds(0.1)) }
        }
        for (name, tab, setUp) in shots {
            setUp()
            // The tabs are toolbar buttons.
            if let toolbar = window?.toolbar {
                let items = toolbar.items.filter { $0.action != nil }
                if tab < items.count, let action = items[tab].action {
                    toolbar.selectedItemIdentifier = items[tab].itemIdentifier
                    NSApp.sendAction(action, to: items[tab].target, from: items[tab])
                }
            }
            await capture(window, to: folder, name)
        }
        window?.close()
    }

    private static func firmware(_ folder: URL) async {
        let sending = Pipeline.InstallProgress(text: "Sending the firmware to the camera…", fraction: 0.4)
        let installing = Pipeline.InstallProgress(text: "", fraction: 1, phase: .installing, restarts: true)
        let finished = Pipeline.InstallProgress(text: "", fraction: 1, finished: true)
        let card = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        let shots: [(String, Pipeline.InstallProgress?, FirmwareView)] = [
            ("01-set-up", nil, FirmwareView(pipeline: pipeline)),
            ("02-getting-the-firmware", nil, FirmwareView(pipeline: pipeline, start: .preparing)),
            ("03-waiting-for-the-card", nil, FirmwareView(pipeline: pipeline, start: .card)),
            ("04-card-found", nil, FirmwareView(pipeline: pipeline, start: .card, cards: [card])),
            ("05-writing-to-the-card", nil, FirmwareView(pipeline: pipeline, start: .writing)),
            ("06-install-from-the-card", nil, FirmwareView(pipeline: pipeline, start: .camera)),
            ("07-ready", nil, FirmwareView(pipeline: pipeline, start: .ready)),
            ("08-update-sending", sending, FirmwareView(pipeline: pipeline, start: .usb, action: .update)),
            ("09-update-installing", installing, FirmwareView(pipeline: pipeline, start: .usb, action: .update)),
            ("10-update-done", finished, FirmwareView(pipeline: pipeline, start: .usb, action: .update)),
            ("11-restore-switch-off-first", .init(text: "", fraction: 0, phase: .switchOffFirst),
             FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
            ("12-restore-sending", sending, FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
            ("13-restore-installing", installing, FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
            ("14-restore-done", finished, FirmwareView(pipeline: pipeline, start: .usb, action: .restore)),
        ]
        pipeline.pretend(status: stockStatus, firmware: .stock)
        for (name, install, view) in shots {
            pipeline.install = install
            await capture(view, to: folder, name)
        }
        // A camera with Mark One's firmware.
        pipeline.pretend(.ready, status: readyStatus, firmware: latest, battery: 100)
        await capture(FirmwareView(pipeline: pipeline), to: folder, "15-manage")
        pipeline.pretend(.ready, status: readyStatus, firmware: latest, battery: 100, reportsOlderVersion: true)
        await capture(FirmwareView(pipeline: pipeline, start: .omWorkspace), to: folder, "16-om-workspace")
    }

    /// Shows a step in a window of its own, so each can start at its step.
    private static func capture(_ view: FirmwareView, to folder: URL, _ name: String) async {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Camera Firmware"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        await capture(window, to: folder, name)
        window.orderOut(nil)
    }

    // MARK: Helpers

    /// The menu bar panel, drawn in a panel of its own like the one the
    /// menu bar icon opens. Clicking the icon isn't reliable: in a full menu
    /// bar it can be hidden behind the camera notch.
    private static func panelWindow() -> NSPanel {
        NSApp.activate(ignoringOtherApps: true)
        let host = NSHostingView(rootView: MenuView(installer: installer, pipeline: pipeline))
        let size = host.fittingSize
        // Solid, so the desktop behind it doesn't show through.
        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        let panel = KeyPanel(contentRect: background.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    /// Key, so its controls draw as they do in the real panel.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static func allow(checked: Bool = true, installed: Bool = false, needsApproval: Bool = false, failed: Bool = false,
                              needsRestart: Bool = false, needsReopen: Bool = false, notInApplications: Bool = false,
                              status: String = "Not installed") {
        installer.checked = checked
        installer.checking = false
        installer.installed = installed
        installer.needsApproval = needsApproval
        installer.failed = failed
        installer.needsRestart = needsRestart
        installer.needsReopen = needsReopen
        installer.notInApplications = notInApplications
        installer.status = installed ? "Installed" : status
    }

    private static let waitingStatus = "Waiting for the camera. Connect it by USB and switch it on."
    private static let readyStatus = "Ready. Pick “Mark One” as the camera in a video app."
    private static let stockStatus = "This camera still has Olympus's firmware. Choose Set Up Camera to add Mark One's."
    private static let photosStatus = "Connected for photos (MTP). To use the camera as a webcam, choose Webcam on its screen when you connect it."
    private static let noCardStatus = "There's no card in the camera. It needs one to record, though Mark One doesn't save anything to it. Updating the camera's firmware removes the need for one."
    private static let restartStatus = "macOS installed the Mark One camera but didn’t start it. Restart your Mac to finish, then open Mark One."
    private static let applicationsStatus = "Mark One needs to be in your Applications folder to add its camera. Quit it, drag it to Applications, and open it from there."

    /// Waits for the window to draw, then grabs it without its shadow.
    private static func capture(_ window: NSWindow?, to folder: URL, _ name: String) async {
        try? await Task.sleep(for: .seconds(0.8))
        guard let window else {
            print("Couldn't find the window for \(folder.lastPathComponent)/\(name).")
            failed = true
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), folder.appendingPathComponent("\(name).png").path]
        try? capture.run()
        capture.waitUntilExit()
        let file = folder.appendingPathComponent("\(name).png")
        guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            print("Couldn't take \(folder.lastPathComponent)/\(name).png.")
            failed = true
            return
        }
        print("Saved \(folder.lastPathComponent)/\(name).png")
    }
}
#endif
