// Runs the whole path from the E-M5 to the Mark One camera: wait for the
// camera on USB, set up the firmware, and while an app uses the Mark One
// camera, record, follow the movie recorder's H.264 stream, decode it and
// send the frames to the camera extension.

import CoreVideo
import Foundation
import os.log

private let log = Logger(subsystem: "com.superhighfives.markone", category: "pipeline")

@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()

    enum State { case waiting, ready, streaming }

    @Published private(set) var state = State.waiting
    @Published private(set) var status = "Starting…"
    @Published private(set) var framesPerSecond = 0.0

    private var thread: Thread?
    private let stopRequested = Flag()
    private var onStopped: [() -> Void] = []

    /// How long to keep recording after the last app stops using the camera,
    /// so switching cameras or settings in an app doesn't restart it.
    private nonisolated static let grace: TimeInterval = 5

    /// Starts watching for the camera. From then on Mark One sets the camera
    /// up whenever it's connected and switched on, and records while an app
    /// uses the Mark One camera.
    func run() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.loop() }
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    /// Stops recording and closes the camera; `done` runs once that's finished.
    func stop(_ done: @escaping () -> Void) {
        guard thread != nil else { return done() }
        onStopped.append(done)
        stopRequested.value = true
    }

    private nonisolated func report(_ text: String, _ state: State? = nil) {
        log.notice("\(text, privacy: .public)")
        Task { @MainActor in
            self.status = text
            if let state { self.state = state }
            if state != .streaming { self.framesPerSecond = 0 }
        }
    }

    private nonisolated func loop() {
        while !stopRequested.value {
            let camera = Camera()
            report("Waiting for the camera. Connect it by USB and switch it on.", .waiting)
            do {
                try camera.connect { !self.stopRequested.value }
                report("Setting up the camera…")
                try Firmware.prepare(camera)
                try serve(camera)
            } catch {
                if !stopRequested.value { report(error.localizedDescription, .waiting) }
                // Wait for the camera to go away before trying it again, so a
                // camera Mark One can't use doesn't get set up over and over.
                if case CameraError.disconnected = error {} else {
                    while camera.connected && !stopRequested.value { Thread.sleep(forTimeInterval: 0.5) }
                }
            }
            let closed = DispatchSemaphore(value: 0)
            camera.disconnect { closed.signal() }
            closed.wait()
        }
        Task { @MainActor in
            self.thread = nil
            self.onStopped.forEach { $0() }
            self.onStopped = []
        }
    }

    /// Records while an app uses the Mark One camera, until the camera goes away.
    private nonisolated func serve(_ camera: Camera) throws {
        let sink = try CameraSink()
        while !stopRequested.value {
            report("Ready. Pick “Mark One” as the camera in a video app.", .ready)
            while !CameraSink.inUse() {
                if stopRequested.value { return }
                if !camera.connected { throw CameraError.disconnected }
                Thread.sleep(forTimeInterval: 0.25)
            }
            try stream(camera, to: sink)
        }
    }

    /// Records and streams until no app has used the camera for `grace` seconds.
    private nonisolated func stream(_ camera: Camera, to sink: CameraSink) throws {
        let decoder = FrameDecoder()
        var shown = 0
        var last: CVPixelBuffer?
        var decoded = false
        decoder.onFrame = { buffer in
            sink.send(buffer)
            last = buffer
            decoded = true
            shown += 1
        }
        let streamer = Streamer(camera: camera)
        var since = Date(), lastUsed = Date(), lastChecked = Date()
        var received = 0, failuresBefore = 0
        let capture = UserDefaults.standard.bool(forKey: "SaveCapture") ? Capture() : nil
        report("Starting to record…", .streaming)
        try Firmware.setRecording(camera, true)
        defer {
            if camera.connected {
                report("Stopping the recording…")
                try? Firmware.setRecording(camera, false)
            }
        }
        while !stopRequested.value {
            let frames = try streamer.poll()
            received += frames.count
            for frame in frames {
                let before = decoder.failures
                decoded = false
                decoder.decode(frame)
                capture?.add(frame, failed: decoder.failures != before)
                // While the decoder waits for a keyframe, repeat the
                // last picture so apps see a short freeze, not a gap.
                if !decoded, let last { sink.send(last) }
            }
            if frames.isEmpty { Thread.sleep(forTimeInterval: 0.003) }
            if Date().timeIntervalSince(lastChecked) >= 0.5 {
                lastChecked = Date()
                if CameraSink.inUse() { lastUsed = lastChecked }
                if lastChecked.timeIntervalSince(lastUsed) >= Pipeline.grace { return }
            }
            let elapsed = Date().timeIntervalSince(since)
            if elapsed >= 2 {
                let rate = Double(shown) / elapsed
                let live = streamer.streaming
                let detail = String(format: "%.0f received, %d failed to decode", Double(received) / elapsed,
                                    decoder.failures - failuresBefore)
                Task { @MainActor in
                    self.framesPerSecond = rate
                    self.status = live ? "Streaming (\(detail))." : "Waiting for video from the camera."
                }
                shown = 0
                received = 0
                failuresBefore = decoder.failures
                since = Date()
            }
        }
    }
}

/// A Bool shared between threads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Saves the first 1800 frames (one minute) to the Downloads folder, with a list of
/// the frames the decoder rejected, for looking into decoding failures. Turn it
/// on with `defaults write com.superhighfives.markone SaveCapture -bool YES`.
final class Capture {
    private let stream: FileHandle?
    private var log = ""
    private var count = 0
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    init() {
        let url = folder.appendingPathComponent("markone-capture.h264")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        stream = try? FileHandle(forWritingTo: url)
    }

    func add(_ frame: Data, failed: Bool) {
        guard count < 1800, let stream else { return }
        stream.write(frame)
        log += "\(count) \(frame.count)\(failed ? " failed" : "")\n"
        count += 1
        if count == 1800 {
            try? stream.close()
            try? log.write(to: folder.appendingPathComponent("markone-capture.txt"), atomically: true, encoding: .utf8)
        }
    }
}
