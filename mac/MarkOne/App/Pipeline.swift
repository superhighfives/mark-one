// Runs the whole path from the E-M5 to the Mark One camera: connect over
// USB, set up the firmware, follow the movie recorder's H.264 stream,
// decode it and send the frames to the camera extension.

import CoreVideo
import Foundation

@MainActor
final class Pipeline: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Not started."
    @Published private(set) var framesPerSecond = 0.0

    private var thread: Thread?
    private let stopRequested = Flag()

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

    func stop() {
        stopRequested.value = true
    }

    private nonisolated func report(_ text: String) {
        Task { @MainActor in self.status = text }
    }

    private nonisolated func loop() {
        let camera = Camera()
        defer {
            camera.disconnect()
            Task { @MainActor in
                self.running = false
                self.framesPerSecond = 0
            }
        }
        do {
            try camera.connect()
            report("Setting up the camera…")
            try Firmware.prepare(camera)
            let sink = try CameraSink()
            let decoder = FrameDecoder()
            var shown = 0
            decoder.onFrame = { buffer in
                sink.send(buffer)
                shown += 1
            }
            let streamer = Streamer(camera: camera)
            var since = Date()
            report("Press record on the camera.")
            while !stopRequested.value {
                let frames = try streamer.poll()
                for frame in frames { decoder.decode(frame) }
                if frames.isEmpty { Thread.sleep(forTimeInterval: 0.003) }
                let elapsed = Date().timeIntervalSince(since)
                if elapsed >= 2 {
                    let rate = Double(shown) / elapsed
                    let live = streamer.streaming
                    Task { @MainActor in
                        self.framesPerSecond = rate
                        self.status = live ? "Streaming to the Mark One camera." : "Press record on the camera."
                    }
                    shown = 0
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
