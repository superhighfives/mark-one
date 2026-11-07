// Runs the whole path from the E-M5 to the Mark One camera: connect over
// USB, set up the firmware, follow the movie recorder's H.264 stream,
// decode it and send the frames to the camera extension.

import CoreVideo
import Foundation

@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()

    @Published private(set) var running = false
    @Published private(set) var status = "Not started."
    @Published private(set) var framesPerSecond = 0.0

    private var thread: Thread?
    private let stopRequested = Flag()
    private var onStopped: [() -> Void] = []

    func start() {
        guard !running else { return }
        running = true
        stopRequested.value = false
        status = "Looking for the camera…"
        let thread = Thread { [weak self] in self?.loop() }
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    /// Stops streaming; `done` runs once the camera session is closed.
    func stop(_ done: (() -> Void)? = nil) {
        if let done {
            if running { onStopped.append(done) } else { done() }
        }
        stopRequested.value = true
    }

    private nonisolated func report(_ text: String) {
        Task { @MainActor in self.status = text }
    }

    private nonisolated func loop() {
        let camera = Camera()
        defer {
            camera.disconnect {
                Task { @MainActor in
                    self.running = false
                    self.framesPerSecond = 0
                    self.onStopped.forEach { $0() }
                    self.onStopped = []
                }
            }
        }
        do {
            try camera.connect()
            report("Setting up the camera…")
            try Firmware.prepare(camera)
            let sink = try CameraSink()
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
            var since = Date()
            var received = 0, failuresBefore = 0
            let capture = UserDefaults.standard.bool(forKey: "SaveCapture") ? Capture() : nil
            report("Starting to record…")
            try Firmware.setRecording(camera, true)
            defer {
                report("Stopping the recording…")
                try? Firmware.setRecording(camera, false)
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
                let elapsed = Date().timeIntervalSince(since)
                if elapsed >= 2 {
                    let rate = Double(shown) / elapsed
                    let live = streamer.streaming
                    let detail = String(format: "%.0f received, %d failed to decode", Double(received) / elapsed,
                                        decoder.failures - failuresBefore)
                    Task { @MainActor in
                        self.framesPerSecond = rate
                        self.status = live ? "Streaming to the Mark One camera (\(detail))." : "Waiting for video from the camera."
                    }
                    shown = 0
                    received = 0
                    failuresBefore = decoder.failures
                    since = Date()
                }
            }
            report("Stopped.")
        } catch {
            report(error.localizedDescription)
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
