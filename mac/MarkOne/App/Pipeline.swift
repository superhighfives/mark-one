// Runs the whole path from the E-M5 to the Mark One camera: wait for the
// camera on USB, set up the firmware, and while an app uses the Mark One
// camera or the panel shows its preview, record, follow the movie recorder's H.264 stream, decode it and
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

    /// Whether the camera's buttons are locked while Mark One uses it.
    @Published var lockControls = UserDefaults.standard.object(forKey: "LockCameraControls") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lockControls, forKey: "LockCameraControls")
            lockWanted.value = lockControls
        }
    }
    private let lockWanted = Flag()

    /// Exposure compensation in thirds of a stop, -9 to 9.
    @Published var brightness = UserDefaults.standard.integer(forKey: "Brightness") {
        didSet {
            UserDefaults.standard.set(brightness, forKey: "Brightness")
            brightnessWanted.value = brightness
        }
    }
    private let brightnessWanted = Locked(0)
    private let focusRequested = Flag()
    @Published private(set) var focusing = false

    /// Focuses the camera, as a half press of its shutter button does.
    func focus() {
        focusing = true
        focusRequested.value = true
    }

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
        lockWanted.value = lockControls
        brightnessWanted.value = brightness
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
                Thread.sleep(forTimeInterval: 1)
                let saved = try Firmware.applyPresets(camera)
                defer { if camera.connected { try? Firmware.releasePresets(camera, saved) } }
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

    /// The controls last sent to the camera.
    private struct Applied {
        var locked: Bool?
        var brightness: Int?
        var focusUntil: Date?
    }

    /// Sends the panel's controls to the camera when they change.
    private nonisolated func updateControls(_ camera: Camera, _ applied: inout Applied) throws {
        let locked = lockWanted.value, brightness = brightnessWanted.value
        if applied.locked != locked {
            try Firmware.setControlsLocked(camera, locked)
            applied.locked = locked
        }
        if applied.brightness != brightness {
            try Firmware.setBrightness(camera, brightness)
            applied.brightness = brightness
        }
        // Focus holds the shutter button half down for two seconds, long
        // enough for the camera to finish focusing, and keeps streaming
        // meanwhile.
        if focusRequested.value {
            focusRequested.value = false
            if applied.focusUntil == nil { try Firmware.startFocus(camera) }
            applied.focusUntil = Date() + 2
        } else if let until = applied.focusUntil, Date() >= until {
            applied.focusUntil = nil
            try Firmware.endFocus(camera)
            Task { @MainActor in self.focusing = false }
        }
    }

    /// Whether anything wants video: an app using the Mark One camera, or
    /// the preview in Mark One's panel.
    private nonisolated func wanted() -> Bool {
        Preview.shared.visible || CameraSink.inUse()
    }

    /// Records while an app uses the Mark One camera, until the camera goes away.
    private nonisolated func serve(_ camera: Camera) throws {
        let sink = try CameraSink()
        var applied = Applied()
        while !stopRequested.value {
            report("Ready. Pick “Mark One” as the camera in a video app.", .ready)
            try Firmware.setScreen(camera, false)
            while !wanted() {
                if stopRequested.value { return }
                if !camera.connected { throw CameraError.disconnected }
                try updateControls(camera, &applied)
                Thread.sleep(forTimeInterval: 0.25)
            }
            try stream(camera, to: sink, applied: &applied)
        }
    }

    /// Records and streams until no app has used the camera for `grace` seconds.
    private nonisolated func stream(_ camera: Camera, to sink: CameraSink, applied: inout Applied) throws {
        let decoder = FrameDecoder()
        var shown = 0
        var last: CVPixelBuffer?
        var decoded = false
        decoder.onFrame = { buffer in
            sink.send(buffer)
            Preview.shared.show(buffer)
            last = buffer
            decoded = true
            shown += 1
        }
        let streamer = Streamer(camera: camera)
        var since = Date(), lastUsed = Date(), lastChecked = Date()
        var received = 0, failuresBefore = 0
        let capture = UserDefaults.standard.bool(forKey: "SaveCapture") ? Capture() : nil
        report("Starting to record…", .streaming)
        try Firmware.setScreen(camera, true)
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
            try updateControls(camera, &applied)
            if Date().timeIntervalSince(lastChecked) >= 0.5 {
                lastChecked = Date()
                if wanted() { lastUsed = lastChecked }
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

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

typealias Flag = Locked<Bool>

extension Locked where Value == Bool {
    convenience init() { self.init(false) }
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
