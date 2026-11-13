// Restarts FaceTime's video service once the Mark One camera is switched on,
// so FaceTime lists it.

import Foundation
import os

private let log = Logger(subsystem: "com.superhighfives.markone", category: "extension")

enum VideoServices {
    /// FaceTime hands the camera to `avconferenced`, which keeps running
    /// after FaceTime quits and keeps the camera list it started with, so it
    /// doesn't see the Mark One camera once it's switched on (see "FaceTime"
    /// and "Processes don't see the camera come back" in NOTES.md).
    /// Restarting it, which launchd does when it's next needed, fixes that.
    /// It runs as the user, so no password. Skipped while a camera is in use,
    /// because that would drop a call.
    static func restartFaceTimeService() {
        guard !CameraSink.anyInUse() else {
            log.notice("Not restarting avconferenced: a camera is in use")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["avconferenced"]
        do {
            try process.run()
            log.notice("Restarted avconferenced, so FaceTime lists the Mark One camera")
        } catch {
            log.error("Couldn't restart avconferenced: \(error.localizedDescription)")
        }
    }
}
