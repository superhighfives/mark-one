// Runs the whole path from the E-M5 to the Mark One camera: wait for the
// camera on USB, set up the firmware, and while an app uses the Mark One
// camera or the panel shows its preview, record, follow the movie recorder's H.264 stream, decode it and
// send the frames to the camera extension.

import AppKit
import CoreVideo
import os.log

private let log = Logger(subsystem: "com.superhighfives.markone", category: "pipeline")

@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()

    enum State { case waiting, ready, streaming }

    @Published private(set) var state = State.waiting
    @Published private(set) var status = "Starting…"
    @Published private(set) var framesPerSecond = 0.0

    /// Why Mark One is waiting, when it's something the user can fix.
    enum Problem { case cameraOff, wrongFirmware, connectedForPhotos }
    @Published private(set) var problem: Problem?

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

    /// Whether the camera keeps refocusing by itself while recording,
    /// rather than only when asked to with Focus.
    @Published var continuousFocus = UserDefaults.standard.bool(forKey: "ContinuousAutofocus") {
        didSet {
            UserDefaults.standard.set(continuousFocus, forKey: "ContinuousAutofocus")
            continuousWanted.value = continuousFocus
        }
    }
    private let continuousWanted = Flag()

    /// The camera's white balance, as values of setting 0x0b.
    enum WhiteBalance: UInt32, CaseIterable, Identifiable {
        case auto = 0, daylight = 6, cloudy = 7, shade = 8, incandescent = 1, fluorescent = 3
        var id: Self { self }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .daylight: "Daylight"
            case .cloudy: "Cloudy"
            case .shade: "Shade"
            case .incandescent: "Incandescent"
            case .fluorescent: "Fluorescent"
            }
        }
    }

    /// The camera's picture mode, as values of setting 0xac.
    enum PictureMode: UInt32, CaseIterable, Identifiable {
        case iEnhance = 7, vivid = 0, natural = 1, muted = 2, portrait = 5, monotone = 3
        var id: Self { self }
        var label: String {
            switch self {
            case .iEnhance: "i-Enhance"
            case .vivid: "Vivid"
            case .natural: "Natural"
            case .muted: "Muted"
            case .portrait: "Portrait"
            case .monotone: "Monotone"
            }
        }
    }

    @Published var whiteBalance = UInt32(exactly: UserDefaults.standard.integer(forKey: "WhiteBalance")).flatMap { WhiteBalance(rawValue: $0) } ?? .auto {
        didSet {
            UserDefaults.standard.set(Int(whiteBalance.rawValue), forKey: "WhiteBalance")
            whiteBalanceWanted.value = whiteBalance.rawValue
        }
    }
    private let whiteBalanceWanted = Locked(WhiteBalance.auto.rawValue)

    @Published var pictureMode = UInt32(exactly: UserDefaults.standard.object(forKey: "PictureMode") as? Int ?? 1).flatMap { PictureMode(rawValue: $0) } ?? .natural {
        didSet {
            UserDefaults.standard.set(Int(pictureMode.rawValue), forKey: "PictureMode")
            pictureModeWanted.value = pictureMode.rawValue
        }
    }
    private let pictureModeWanted = Locked(PictureMode.natural.rawValue)

    /// Whether autofocus looks for faces first.
    @Published var faceFocus = UserDefaults.standard.object(forKey: "FacePriority") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(faceFocus, forKey: "FacePriority")
            faceWanted.value = faceFocus
        }
    }
    private let faceWanted = Flag()

    /// The camera's battery level, 1 to 100, while it's connected.
    @Published private(set) var battery: Int?

    private let focusRequested = Flag()
    @Published private(set) var focusing = false

    /// What the camera is doing while the preview freezes (starting to
    /// record, switching autofocus), for the preview's overlay.
    @Published private(set) var busy: String?

    private nonisolated func setBusy(_ text: String?) {
        clearBusyOnFrame.value = text != nil
        Task { @MainActor in self.busy = text }
    }
    /// Set while the overlay waits for the next picture to clear it.
    private let clearBusyOnFrame = Flag()

    /// Focuses the camera, as a half press of its shutter button does.
    func focus() {
        focusing = true
        focusRequested.value = true
    }

    /// Which firmware the connected camera has, once Mark One has checked.
    @Published private(set) var firmware: CameraFirmware?

    struct InstallProgress: Equatable {
        var text: String
        var fraction: Double
        var finished = false
        var error: String?
        /// What the camera should report once the install is done.
        var expected: CameraFirmware?
        var phase = Phase.sending

        enum Phase: Equatable {
            case sending
            /// The camera has the firmware and is installing it by itself.
            case installing
        }
    }
    /// A USB firmware install, while one runs and after it ends.
    @Published var install: InstallProgress?
    private let installImage = Locked<FirmwareImage?>(nil)

    /// Installs Mark One's firmware over USB. The camera has to have Mark
    /// One's firmware already; recording stops first.
    func installOverUSB(_ image: FirmwareImage) {
        let expected: CameraFirmware = image.revision == 0 ? .stock : .markOne(image.revision)
        install = InstallProgress(text: "Getting the camera ready…", fraction: 0, expected: expected)
        installImage.value = image
    }

    /// Makes the camera report firmware 1.0 until it's switched off, so
    /// Olympus's OM Workspace offers to install 2.3 on it.
    func reportOlderVersion() {
        olderVersionRequested.value = true
    }
    private let olderVersionRequested = Flag()
    /// Whether the camera reports 1.0 now.
    @Published private(set) var reportsOlderVersion = false

    private nonisolated func installProgress(_ progress: InstallProgress) {
        Task { @MainActor in self.install = progress }
    }

    private var thread: Thread?
    private let stopRequested = Flag()
    private var onStopped: [() -> Void] = []

    /// How long to keep recording after the last app stops using the camera.
    enum Grace: TimeInterval, CaseIterable, Identifiable {
        case short = 5, medium = 30, long = 120
        var id: Self { self }
        var duration: String {
            switch self {
            case .short: "5 seconds"
            case .medium: "30 seconds"
            case .long: "2 minutes"
            }
        }
        var label: String { "After \(duration)" }
    }

    /// How long to keep recording after the last app stops using the camera,
    /// so switching cameras or settings in an app doesn't restart it.
    @Published var grace = Grace(rawValue: UserDefaults.standard.double(forKey: "StopDelay")) ?? .short {
        didSet {
            UserDefaults.standard.set(grace.rawValue, forKey: "StopDelay")
            graceWanted.value = grace.rawValue
        }
    }
    private let graceWanted = Locked(Grace.short.rawValue)

    /// The app using the Mark One camera, for "In use by FaceTime". Nil
    /// when no app is, or when macOS doesn't give it a name.
    @Published private(set) var activeApp: String?

    private nonisolated func showClient(_ pid: pid_t?) {
        Task { @MainActor in
            self.activeApp = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        }
    }

    /// Starts watching for the camera. From then on Mark One sets the camera
    /// up whenever it's connected and switched on, and records while an app
    /// uses the Mark One camera.
    func run() {
        guard thread == nil else { return }
        lockWanted.value = lockControls
        brightnessWanted.value = brightness
        continuousWanted.value = continuousFocus
        graceWanted.value = grace.rawValue
        whiteBalanceWanted.value = whiteBalance.rawValue
        pictureModeWanted.value = pictureMode.rawValue
        faceWanted.value = faceFocus
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

    private nonisolated func note(_ problem: Problem?) {
        Task { @MainActor in self.problem = problem }
    }

    private nonisolated func loop() {
        while !stopRequested.value {
            let camera = Camera()
            report("Waiting for the camera. Connect it by USB and switch it on.", .waiting)
            do {
                try camera.connect { !self.stopRequested.value }
                note(nil)
                let firmware = try Firmware.identify(camera)
                Task { @MainActor in
                    self.firmware = firmware
                    // The camera is back after an install.
                    if let install = self.install, install.error == nil, !install.finished,
                       self.installImage.value == nil, install.expected == firmware {
                        self.install = InstallProgress(text: "Installed.", fraction: 1, finished: true, expected: firmware)
                    }
                }
                if firmware == .stock {
                    report("This camera still has Olympus's firmware. Choose Set Up Camera to add Mark One's.", .waiting)
                    while camera.connected && !stopRequested.value { Thread.sleep(forTimeInterval: 0.5) }
                    throw CameraError.disconnected
                }
                try installIfRequested(camera)
                // With the Webcam USB choice, leave the camera alone when it
                // connects as MTP or Storage, so it still works for photos
                // and firmware updates.
                if case .markOne(let revision) = firmware, revision >= 1,
                   try Firmware.connectionType(camera) != Firmware.webcamConnection {
                    report("Connected for photos (MTP). To use the camera as a webcam, choose Webcam on its screen when you connect it.", .waiting)
                    note(.connectedForPhotos)
                    while camera.connected && !stopRequested.value {
                        if installImage.value != nil { try installIfRequested(camera) }
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    throw CameraError.disconnected
                }
                report("Setting up the camera…")
                try Firmware.prepare(camera)
                Thread.sleep(forTimeInterval: 1)
                let saved = try Firmware.applyPresets(camera)
                defer { if camera.connected { try? Firmware.releasePresets(camera, saved) } }
                try serve(camera)
            } catch PipelineInterrupt.install {
                // Recording has stopped and the camera's settings are back.
                // Installing from here, in the shooting mode Mark One set
                // up, works; the camera's screen just flickers between the
                // update icons and the last live picture while it installs.
                try? installIfRequested(camera)
            } catch {
                if !stopRequested.value {
                    report(error.localizedDescription, .waiting)
                    note(Problem(error))
                }
                // Wait for the camera to go away before trying it again, so a
                // camera Mark One can't use doesn't get set up over and over.
                if case CameraError.disconnected = error {} else {
                    while camera.connected && !stopRequested.value { Thread.sleep(forTimeInterval: 0.5) }
                }
            }
            let closed = DispatchSemaphore(value: 0)
            camera.disconnect { closed.signal() }
            closed.wait()
            Task { @MainActor in
                self.firmware = nil
                self.battery = nil
                self.reportsOlderVersion = false
            }
        }
        Task { @MainActor in
            self.thread = nil
            self.onStopped.forEach { $0() }
            self.onStopped = []
        }
    }

    /// Runs a requested USB install. Once the camera starts installing it
    /// restarts by itself, so the session ends here either way.
    private nonisolated func installIfRequested(_ camera: Camera) throws {
        guard let image = installImage.value else { return }
        installImage.value = nil
        report("Installing Mark One's firmware…", .waiting)
        do {
            try FirmwareInstall.overUSB(camera, image) { text, fraction in
                installProgress(InstallProgress(text: text, fraction: fraction))
            }
        } catch {
            installProgress(InstallProgress(text: "", fraction: 0, finished: true, error: error.localizedDescription,
                                            expected: nil))
            throw error
        }
        let expected: CameraFirmware = image.revision == 0 ? .stock : .markOne(image.revision)
        installProgress(InstallProgress(text: "The camera is installing.", fraction: 0.5, expected: expected, phase: .installing))
        // The camera drops off USB while it installs and comes back as
        // itself once it's done.
        while camera.connected && !stopRequested.value { Thread.sleep(forTimeInterval: 0.5) }
        throw CameraError.disconnected
    }

    /// The controls last sent to the camera.
    private struct Applied {
        var locked: Bool?
        var brightness: Int?
        var continuous: Bool?
        var whiteBalance: UInt32?
        var pictureMode: UInt32?
        var face: Bool?
        var batteryChecked = Date.distantPast
        let focus = FocusWatch()
    }

    /// Sends the panel's controls to the camera when they change.
    private nonisolated func updateControls(_ camera: Camera, _ applied: inout Applied, recording: Bool = false) throws {
        if olderVersionRequested.value {
            olderVersionRequested.value = false
            try Firmware.reportVersion(camera, major: 1, minor: 0)
            Task { @MainActor in self.reportsOlderVersion = true }
        }
        let locked = lockWanted.value, brightness = brightnessWanted.value, continuous = continuousWanted.value
        if applied.locked != locked {
            try Firmware.setControlsLocked(camera, locked)
            applied.locked = locked
        }
        if applied.continuous != continuous {
            // The camera reads the autofocus mode when a recording starts,
            // so restart the recording to switch it right away. The picture
            // freezes for about a second.
            let restart = recording && applied.continuous != nil
            if restart {
                setBusy(continuous ? "Turning on continuous autofocus…" : "Turning off continuous autofocus…")
                try Firmware.setRecording(camera, false)
            }
            do {
                try Firmware.setContinuousFocus(camera, continuous)
                if restart { try Firmware.setRecording(camera, true) }
            } catch {
                if restart { setBusy(nil) }
                throw error
            }
            applied.continuous = continuous
        }
        if applied.brightness != brightness {
            try Firmware.setBrightness(camera, brightness)
            applied.brightness = brightness
        }
        let whiteBalance = whiteBalanceWanted.value, pictureMode = pictureModeWanted.value, face = faceWanted.value
        if applied.whiteBalance != whiteBalance {
            try Firmware.writeSetting(camera, Firmware.whiteBalance, whiteBalance)
            applied.whiteBalance = whiteBalance
        }
        if applied.pictureMode != pictureMode {
            try Firmware.writeSetting(camera, Firmware.pictureMode, pictureMode)
            applied.pictureMode = pictureMode
        }
        if applied.face != face {
            try Firmware.writeSetting(camera, Firmware.facePriority, face ? 1 : 0)
            applied.face = face
        }
        if Date().timeIntervalSince(applied.batteryChecked) >= 30 {
            applied.batteryChecked = Date()
            let level = try Firmware.battery(camera)
            Task { @MainActor in self.battery = level }
        }
        // Focus holds the shutter button half down until the picture
        // settles, and keeps streaming meanwhile.
        if focusRequested.value {
            focusRequested.value = false
            if !applied.focus.active {
                try Firmware.startFocus(camera)
                applied.focus.start()
            }
        } else if applied.focus.active && applied.focus.done {
            applied.focus.stop()
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
                if installImage.value != nil { throw PipelineInterrupt.install }
                if !camera.connected { throw CameraError.disconnected }
                try updateControls(camera, &applied)
                Thread.sleep(forTimeInterval: 0.25)
            }
            try stream(camera, to: sink, applied: &applied)
        }
    }

    /// Records and streams until nothing has wanted video for `grace`.
    private nonisolated func stream(_ camera: Camera, to sink: CameraSink, applied: inout Applied) throws {
        let decoder = FrameDecoder()
        var shown = 0
        var last: CVPixelBuffer?
        var decoded = false
        let focus = applied.focus
        decoder.onFrame = { [weak self] buffer in
            if let self, self.clearBusyOnFrame.value { self.setBusy(nil) }
            focus.measure(buffer)
            sink.send(buffer)
            Preview.shared.show(buffer)
            last = buffer
            decoded = true
            shown += 1
        }
        let streamer = Streamer(camera: camera)
        var since = Date(), lastUsed = Date(), lastChecked = Date()
        var received = 0, failuresBefore = 0
        var lastReceived = Date()
        var client: pid_t?
        let capture = UserDefaults.standard.bool(forKey: "SaveCapture") ? Capture() : nil
        report("Starting to record…", .streaming)
        setBusy("Starting the camera…")
        try Firmware.setScreen(camera, true)
        try Firmware.setRecording(camera, true)
        defer {
            setBusy(nil)
            showClient(nil)
            if camera.connected {
                report("Stopping the recording…")
                try? Firmware.setRecording(camera, false)
            }
        }
        while !stopRequested.value {
            if installImage.value != nil { throw PipelineInterrupt.install }
            let frames = try streamer.poll()
            received += frames.count
            if !frames.isEmpty {
                // Apps fill gaps with the last picture, then a gray one after
                // 3 seconds. Log each gap to find out what causes them.
                let gap = Date().timeIntervalSince(lastReceived)
                if gap > 0.2 {
                    log.notice("No video from the camera for \(gap, format: .fixed(precision: 2), privacy: .public) s, then \(frames.count, privacy: .public) frames at once")
                }
                lastReceived = Date()
            }
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
            try updateControls(camera, &applied, recording: true)
            if Date().timeIntervalSince(lastChecked) >= 0.5 {
                lastChecked = Date()
                if wanted() { lastUsed = lastChecked }
                if lastChecked.timeIntervalSince(lastUsed) >= graceWanted.value { return }
                let now = CameraSink.client()
                if now != client {
                    client = now
                    showClient(now)
                }
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

/// Unwinds the camera session so something else can use the camera.
enum PipelineInterrupt: Error {
    case install
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

/// Saves the first 1800 frames (one minute), with a list of the frames the
/// decoder rejected, for looking into decoding failures. Turn it on with
/// `defaults write com.superhighfives.markone SaveCapture -bool YES`. The
/// files go in the app's sandbox container, in
/// ~/Library/Containers/com.superhighfives.markone/Data/Library/Caches.
final class Capture {
    private let stream: FileHandle?
    private var log = ""
    private var count = 0
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

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

/// Tells when the camera has finished focusing. The camera doesn't say so
/// while recording, so this watches the picture instead: sharpness in the
/// middle of the frame falls while the lens searches, then rises and
/// holds once it's found focus. Lives on the worker thread.
final class FocusWatch {
    /// The longest the shutter button stays half pressed.
    static let limit: TimeInterval = 5
    /// The search takes a moment to start after the press.
    static let minimum: TimeInterval = 0.8

    private(set) var active = false
    private var started = Date.distantPast
    private var best = 0.0
    private var recent: [Double] = []

    func start() {
        active = true
        started = Date()
        best = 0
        recent = []
    }

    func stop() { active = false }

    /// Settled: the last quarter second of frames agree within 8 percent,
    /// near the sharpest picture seen since the press.
    var done: Bool {
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= FocusWatch.limit { return true }
        guard elapsed >= FocusWatch.minimum, recent.count == 8,
              let low = recent.min(), let high = recent.max() else { return false }
        return high - low <= 0.08 * high && recent.last! >= 0.7 * best
    }

    func measure(_ buffer: CVPixelBuffer) {
        guard active else { return }
        let value = FocusWatch.sharpness(buffer)
        best = max(best, value)
        recent.append(value)
        if recent.count > 8 { recent.removeFirst() }
    }

    /// The spread of a simple edge filter over the middle of the brightness
    /// plane: high when the picture is sharp.
    static func sharpness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let size = min(400, width - 2, height - 2), left = (width - size) / 2, top = (height - size) / 2
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in Swift.stride(from: top + 1, to: top + size - 1, by: 2) {
            let row = pixels + y * stride
            for x in Swift.stride(from: left + 1, to: left + size - 1, by: 2) {
                let edge = 4 * Double(row[x]) - Double(row[x - 1]) - Double(row[x + 1])
                    - Double(row[x - stride]) - Double(row[x + stride])
                sum += edge
                squares += edge * edge
                count += 1
            }
        }
        let mean = sum / count
        return squares / count - mean * mean
    }
}

private extension Pipeline.Problem {
    init?(_ error: Error) {
        switch error {
        case CameraError.disconnected: self = .cameraOff
        case FirmwareError.unexpected: self = .wrongFirmware
        default: return nil
        }
    }
}
