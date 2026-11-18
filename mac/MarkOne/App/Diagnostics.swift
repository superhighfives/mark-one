// For tracking down problems that happen while nobody's watching, such as
// the camera not coming back after the Mac sleeps overnight. Mark One logs
// to the system log under com.superhighfives.markone; this adds the Mac's
// sleep and wake, a once-a-minute line about what Mark One is waiting for
// (with Detailed logging on, in Settings), and saving the log to a file.
//
// From Terminal, the same log:
//   log show --last 1d --predicate 'subsystem BEGINSWITH "com.superhighfives.markone"'

import AppKit
import os.log
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.superhighfives.markone", category: "diagnostics")

enum Diagnostics {
    /// Whether to log a line a minute while Mark One waits. Mirrors
    /// Preferences.detailedLogging, for the pipeline's thread.
    static let detailed = Flag()

    private static let lastHeartbeat = Locked(Date.distantPast)

    /// Logs the Mac going to sleep and waking. Call once at launch.
    @MainActor static func start() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "The Mac is going to sleep"),
            (NSWorkspace.didWakeNotification, "The Mac woke up"),
            (NSWorkspace.screensDidSleepNotification, "The display went to sleep"),
            (NSWorkspace.screensDidWakeNotification, "The display woke up"),
        ]
        for (name, text) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                log.notice("\(text, privacy: .public)")
            }
        }
    }

    /// With Detailed logging on, logs what Mark One is doing at most once a
    /// minute, and whether an app is using the Mark One camera meanwhile.
    static func heartbeat(_ doing: @autoclosure () -> String) {
        guard detailed.value, Date().timeIntervalSince(lastHeartbeat.value) >= 60 else { return }
        lastHeartbeat.value = Date()
        let doing = doing()
        let used = CameraSink.inUse() ? "an app is using the Mark One camera" : "no app is using the Mark One camera"
        log.notice("\(doing, privacy: .public); \(used, privacy: .public)")
    }

    /// Asks where to save the last 3 days of Mark One's log, saves it and
    /// shows it in the Finder.
    @MainActor static func saveLog() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mark One Log \(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let error = write(to: url)
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t save the log"
                    alert.informativeText = error
                    alert.runModal()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    /// Runs `log show` into the file; returns why it failed, if it did.
    private static func write(to url: URL) -> String? {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else { return "Mark One can’t write to \(url.path)." }
        defer { try? file.close() }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        file.write(Data("Mark One \(version), macOS \(os)\n\n".utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "3d", "--style", "compact",
                             "--predicate", "subsystem BEGINSWITH \"com.superhighfives.markone\""]
        process.standardOutput = file
        process.standardError = file
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        return process.terminationStatus == 0 ? nil : "The log tool stopped with status \(process.terminationStatus). The file has what it wrote."
    }
}
