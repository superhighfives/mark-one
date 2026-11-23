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
    enum Problem { case cameraOff, wrongFirmware, connectedForPhotos, noCard }
    @Published private(set) var problem: Problem?

    /// Whether the camera's buttons are locked while Mark One uses it.
    @Published var lockControls = UserDefaults.standard.object(forKey: "LockCameraControls") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lockControls, forKey: "LockCameraControls")
            lockWanted.value = lockControls
        }
    }
    private let lockWanted = Flag()

    /// Whether the camera connects as a webcam without asking: Mark One sets
    /// its USB Mode to Webcam, or back to Auto when this is off.
    @Published var connectAsWebcam = UserDefaults.standard.object(forKey: "ConnectAsWebcam") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(connectAsWebcam, forKey: "ConnectAsWebcam")
            webcamWanted.value = connectAsWebcam
        }
    }
    private let webcamWanted = Flag()

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

    /// How the camera sets its exposure for movies, as values of setting
    /// 0xff. The camera reads it, and the aperture, shutter speed and ISO,
    /// only when a recording starts.
    enum ExposureMode: UInt32, CaseIterable, Identifiable {
        case auto = 76, aperture = 77, shutter = 89, manual = 90
        var id: Self { self }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .aperture: "Aperture priority"
            case .shutter: "Shutter priority"
            case .manual: "Manual"
            }
        }
        var setsAperture: Bool { self == .aperture || self == .manual }
        var setsShutter: Bool { self == .shutter || self == .manual }
    }

    /// Apertures in thirds of a stop (APEX Av × 3): f/1.4 is Av 1.
    enum Aperture: Int, CaseIterable, Identifiable {
        case f1_4 = 3, f2 = 6, f2_8 = 9, f4 = 12, f5_6 = 15, f8 = 18, f11 = 21, f16 = 24
        var id: Self { self }
        var label: String {
            switch self {
            case .f1_4: "f/1.4"
            case .f2: "f/2"
            case .f2_8: "f/2.8"
            case .f4: "f/4"
            case .f5_6: "f/5.6"
            case .f8: "f/8"
            case .f11: "f/11"
            case .f16: "f/16"
            }
        }
        /// Setting 0x04's value: APEX × 256, rounded down as the camera does.
        var value: UInt32 { UInt32(rawValue * 256 / 3) }
    }

    /// Shutter speeds in thirds of a stop (APEX Tv × 3): 1/60 is Tv 6.
    /// 1/50 and 1/100 match 50 Hz lights, 1/60 and 1/125 60 Hz ones.
    enum ShutterSpeed: Int, CaseIterable, Identifiable {
        case s30 = 15, s50 = 17, s60 = 18, s100 = 20, s125 = 21, s250 = 24, s500 = 27
        var id: Self { self }
        var label: String {
            switch self {
            case .s30: "1/30 s"
            case .s50: "1/50 s"
            case .s60: "1/60 s"
            case .s100: "1/100 s"
            case .s125: "1/125 s"
            case .s250: "1/250 s"
            case .s500: "1/500 s"
            }
        }
        /// Setting 0x05's value: APEX × 256, rounded down as the camera does
        /// (1/100 is 0x6aa).
        var value: UInt32 { UInt32(rawValue * 256 / 3) }
    }

    /// ISO, as values of setting 0x08. Only Manual uses a fixed ISO.
    enum ISO: UInt32, CaseIterable, Identifiable {
        case auto = 0, iso200 = 200, iso400 = 400, iso800 = 800, iso1600 = 1600, iso3200 = 3200, iso6400 = 6400
        var id: Self { self }
        var label: String { self == .auto ? "Auto" : "\(rawValue)" }
    }

    /// Image stabilization, as values of setting 0x1b5: Auto, Vertical only
    /// and Horizontal only are the camera's IS 1, IS 2 and IS 3.
    enum Stabilization: UInt32, CaseIterable, Identifiable {
        case off = 0, auto = 1, vertical = 2, horizontal = 3
        var id: Self { self }
        var label: String {
            switch self {
            case .off: "Off"
            case .auto: "Auto"
            case .vertical: "Vertical only"
            case .horizontal: "Horizontal only"
            }
        }
    }

    /// The settings the camera reads only when a recording starts.
    struct MovieSettings: Equatable {
        var mode: ExposureMode, aperture: Aperture, shutter: ShutterSpeed, iso: ISO, stabilization: Stabilization

        /// The settings to write, mode first: (setting, value).
        var values: [(UInt32, UInt32)] {
            var values = [(Firmware.movieMode, mode.rawValue)]
            if mode.setsAperture { values.append((Firmware.aperture, aperture.value)) }
            if mode.setsShutter { values.append((Firmware.shutterSpeed, shutter.value)) }
            values.append((Firmware.iso, mode == .manual ? iso.rawValue : ISO.auto.rawValue))
            values.append((Firmware.stabilization, stabilization.rawValue))
            return values
        }

        /// Equal when they'd write the same values, so changing a setting
        /// the mode doesn't use (the aperture in Auto) doesn't restart the
        /// recording.
        static func == (a: Self, b: Self) -> Bool { a.values.elementsEqual(b.values) { $0 == $1 } }

        var description: String {
            var parts = [mode.label]
            if mode.setsAperture { parts.append(aperture.label) }
            if mode.setsShutter { parts.append(shutter.label) }
            if mode == .manual { parts.append("ISO \(iso.label)") }
            parts.append("stabilization \(stabilization.label)")
            return parts.joined(separator: ", ")
        }
    }

    @Published var exposureMode = UInt32(exactly: UserDefaults.standard.integer(forKey: "ExposureMode")).flatMap { ExposureMode(rawValue: $0) } ?? .auto {
        didSet {
            UserDefaults.standard.set(Int(exposureMode.rawValue), forKey: "ExposureMode")
            movieSettingsChanged()
        }
    }
    @Published var aperture = Aperture(rawValue: UserDefaults.standard.integer(forKey: "Aperture")) ?? .f2_8 {
        didSet {
            UserDefaults.standard.set(aperture.rawValue, forKey: "Aperture")
            movieSettingsChanged()
        }
    }
    @Published var shutterSpeed = ShutterSpeed(rawValue: UserDefaults.standard.integer(forKey: "ShutterSpeed")) ?? .s60 {
        didSet {
            UserDefaults.standard.set(shutterSpeed.rawValue, forKey: "ShutterSpeed")
            movieSettingsChanged()
        }
    }
    @Published var iso = UInt32(exactly: UserDefaults.standard.integer(forKey: "ISO")).flatMap { ISO(rawValue: $0) } ?? .auto {
        didSet {
            UserDefaults.standard.set(Int(iso.rawValue), forKey: "ISO")
            movieSettingsChanged()
        }
    }
    @Published var stabilization = UInt32(exactly: UserDefaults.standard.object(forKey: "Stabilization") as? Int ?? 1)
        .flatMap { Stabilization(rawValue: $0) } ?? .auto {
        didSet {
            UserDefaults.standard.set(Int(stabilization.rawValue), forKey: "Stabilization")
            movieSettingsChanged()
        }
    }
    private func movieSettingsChanged() {
        movieWanted.value = movieSettings
        movieChanged.value = Date()
    }
    private var movieSettings: MovieSettings {
        MovieSettings(mode: exposureMode, aperture: aperture, shutter: shutterSpeed, iso: iso, stabilization: stabilization)
    }
    private let movieWanted = Locked(MovieSettings(mode: .auto, aperture: .f2_8, shutter: .s60, iso: .auto, stabilization: .auto))
    /// When a movie setting last changed. During a call, Mark One waits for
    /// them to settle, so picking a mode and then its aperture, shutter
    /// speed and ISO restarts the recording once.
    private let movieChanged = Locked(Date.distantPast)

    /// Whether the camera focuses once as soon as an app starts using it,
    /// when autofocus is set to Once.
    @Published var focusOnStart = UserDefaults.standard.object(forKey: "FocusOnStart") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(focusOnStart, forKey: "FocusOnStart")
            focusOnStartWanted.value = focusOnStart
        }
    }
    private let focusOnStartWanted = Flag()

    /// Whether video apps get a frame saying why there's no picture, while
    /// the camera isn't ready.
    @Published var showStatusCard = UserDefaults.standard.object(forKey: "ShowStatusCard") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showStatusCard, forKey: "ShowStatusCard")
            card.enabled.value = showStatusCard
        }
    }
    private let card = StatusCard()

    /// Whether autofocus looks for faces first.
    @Published var faceFocus = UserDefaults.standard.object(forKey: "FacePriority") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(faceFocus, forKey: "FacePriority")
            faceWanted.value = faceFocus
        }
    }
    private let faceWanted = Flag()

    /// The camera's battery level while it's connected: nominally 1 to 100,
    /// but only a few steps in practice (see CameraBattery).
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

    /// Whether the panel's Focus button works now: only while recording, with
    /// autofocus set to Once, and not while it's already focusing.
    var canFocus: Bool { state == .streaming && !focusing && !continuousFocus }

    /// Focuses the camera, as a half press of its shutter button does.
    func focus() {
        focusing = true
        focusRequested.value = true
    }

    /// For the shortcut: focuses while recording, switching autofocus to
    /// Once first if it's on Always. Switching pauses the picture for about a
    /// second, and the camera focuses once it's back.
    func focusOnce() {
        guard state == .streaming, !focusing else { return }
        if continuousFocus { continuousFocus = false }
        focus()
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
        /// Whether the camera restarts by itself once it has installed.
        var restarts = false

        enum Phase: Equatable {
            case sending
            /// The camera has the firmware and is installing it by itself.
            case installing
            /// Before restoring, the camera has to be switched off and on so
            /// it saves USB Mode Auto.
            case switchOffFirst
        }
    }
    /// A USB firmware install, while one runs and after it ends.
    @Published var install: InstallProgress?

    /// Whether a USB install is under way, so quitting should wait.
    var updating: Bool {
        guard let install else { return false }
        return !install.finished && install.error == nil
    }
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
        webcamWanted.value = connectAsWebcam
        brightnessWanted.value = brightness
        continuousWanted.value = continuousFocus
        graceWanted.value = grace.rawValue
        whiteBalanceWanted.value = whiteBalance.rawValue
        pictureModeWanted.value = pictureMode.rawValue
        movieWanted.value = movieSettings
        faceWanted.value = faceFocus
        focusOnStartWanted.value = focusOnStart
        card.enabled.value = showStatusCard
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
        // Stopping the recording and handing the controls back takes a
        // moment, with the preview frozen; say so instead of looking stuck.
        if state == .streaming || state == .ready {
            clearBusyOnFrame.value = false
            busy = "Stopping the camera…"
        }
    }

    /// Shows `text` as the status, and `card` to video apps (see
    /// StatusCard) when given.
    private nonisolated func report(_ text: String, _ state: State? = nil, card: String? = nil) {
        log.notice("\(text, privacy: .public)")
        if let card { self.card.show(card) }
        Task { @MainActor in
            self.status = text
            if let state { self.state = state }
            if state != .streaming { self.framesPerSecond = 0 }
        }
    }

    /// Opens the camera extension's input, trying again every 2 seconds
    /// while the camera stays connected. Right after the extension is
    /// installed, updated or allowed, it may not be running yet.
    private nonisolated func openSink(_ camera: Camera) throws -> CameraSink {
        var reported = false
        while true {
            do {
                return try CameraSink()
            } catch {
                if !reported { report(error.localizedDescription, .waiting) }
                reported = true
            }
            for _ in 0..<4 {
                if !camera.connected || stopRequested.value { throw CameraError.disconnected }
                Diagnostics.heartbeat("Waiting for the Mark One camera to start")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private nonisolated func note(_ problem: Problem?) {
        Task { @MainActor in self.problem = problem }
    }

    private nonisolated func loop() {
        while !stopRequested.value {
            let camera = Camera()
            // Opened before the camera connects, for the status card. The
            // error doesn't matter here: if this fails, openSink tries again
            // once the camera connects, and reports why.
            var sink = CameraSink.available ? try? CameraSink() : nil
            card.attach(sink)
            report("Waiting for the camera. Connect it by USB and switch it on.", .waiting,
                   card: "Connect your E-M5 (Mark I) by USB and switch it on")
            do {
                try camera.connect {
                    Diagnostics.heartbeat("Looking for the camera on USB (\(Camera.onUSB() ? "the Mac lists it on USB" : "not on USB"))")
                    return !self.stopRequested.value
                }
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
                    report("This camera still has Olympus's firmware. Choose Set Up Camera to add Mark One's.", .waiting,
                           card: "Set up the camera in Mark One")
                    while camera.connected && !stopRequested.value { Thread.sleep(forTimeInterval: 0.5) }
                    throw CameraError.disconnected
                }
                try installIfRequested(camera)
                // With the Webcam USB choice, leave the camera alone when it
                // connects as MTP or Storage, so it still works for photos
                // and firmware updates.
                if case .markOne(let revision) = firmware, revision >= 1,
                   try Firmware.connectionType(camera) != Firmware.webcamConnection {
                    report("Connected for photos (MTP). To use the camera as a webcam, choose Webcam on its screen when you connect it.", .waiting,
                           card: "Choose Webcam on the camera's screen")
                    note(.connectedForPhotos)
                    while camera.connected && !stopRequested.value {
                        if installImage.value != nil { try installIfRequested(camera) }
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    throw CameraError.disconnected
                }
                let revision: Int
                if case .markOne(let markOne) = firmware { revision = markOne } else { revision = 0 }
                // Before revision 2 of Mark One's firmware, the camera only
                // records with a card in, though Mark One never writes to
                // it. Wait for one.
                let cardless = revision >= 2
                // Revision 3 lists each frame's address and size.
                let frameList = revision >= 3
                if !cardless, try !Firmware.hasCard(camera) {
                    report("There's no card in the camera. It needs one to record, though Mark One doesn't save anything to it. Updating the camera's firmware removes the need for one.", .waiting,
                           card: "Put a card in the camera")
                    note(.noCard)
                    while try !Firmware.hasCard(camera) {
                        if !camera.connected || stopRequested.value { throw CameraError.disconnected }
                        if installImage.value != nil { try installIfRequested(camera) }
                        Thread.sleep(forTimeInterval: 1)
                    }
                    note(nil)
                }
                report("Setting up the camera…", card: "Starting the camera…")
                // Open the camera extension first: setting up locks the
                // camera's buttons and dial, and nothing unlocks them if
                // the extension turns out to be missing.
                let ready = try sink ?? openSink(camera)
                sink = ready
                card.attach(ready)
                try Firmware.prepare(camera, revision: revision)
                Thread.sleep(forTimeInterval: 1)
                let saved = try Firmware.applyPresets(camera)
                defer { if camera.connected { try? Firmware.releasePresets(camera, saved) } }
                try serve(camera, to: ready, frameList: frameList)
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
                // Not when stopping: connect throws notFound then.
                if case CameraError.disconnected = error {} else if !stopRequested.value {
                    log.notice("Waiting for the camera to be switched off or unplugged before trying again")
                    card.show("Switch the camera off and on")
                    while camera.connected && !stopRequested.value {
                        Diagnostics.heartbeat("Still waiting for the camera to be switched off or unplugged, after: \(error.localizedDescription)")
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
            let closed = DispatchSemaphore(value: 0)
            camera.disconnect { closed.signal() }
            closed.wait()
            card.attach(nil)
            Task { @MainActor in
                self.firmware = nil
                self.battery = nil
                self.reportsOlderVersion = false
            }
        }
        card.show(nil)
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
        // Olympus's firmware reads the Webcam USB Mode as Storage. The camera
        // only saves settings when it's switched off, and the install ends
        // without that, so set Auto and have it switched off first. The
        // install carries on when it's back.
        if image.revision == 0, try Firmware.readSetting(camera, Firmware.usbMode) == Firmware.usbWebcam {
            try Firmware.writeSetting(camera, Firmware.usbMode, Firmware.usbAuto)
            installProgress(InstallProgress(text: "", fraction: 0, phase: .switchOffFirst))
            report("Switch the camera off and on to carry on.", .waiting, card: "Switch the camera off and on")
            while camera.connected && !stopRequested.value { Thread.sleep(forTimeInterval: 0.5) }
            throw CameraError.disconnected
        }
        installImage.value = nil
        report("Installing Mark One's firmware…", .waiting, card: "Installing the camera's firmware…")
        let restarts: Bool
        do {
            restarts = try FirmwareInstall.overUSB(camera, image) { text, fraction in
                installProgress(InstallProgress(text: text, fraction: fraction))
            }
        } catch {
            installProgress(InstallProgress(text: "", fraction: 0, finished: true, error: error.localizedDescription,
                                            expected: nil))
            throw error
        }
        let expected: CameraFirmware = image.revision == 0 ? .stock : .markOne(image.revision)
        installProgress(InstallProgress(text: "The camera is installing.", fraction: 0.5, expected: expected, phase: .installing,
                                        restarts: restarts))
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
        var movie: MovieSettings?
        var face: Bool?
        var usbMode: UInt32?
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
        // Not while a restore waits for Auto to be saved (installIfRequested).
        let usbMode = webcamWanted.value ? Firmware.usbWebcam : Firmware.usbAuto
        if applied.usbMode != usbMode, installImage.value?.revision != 0 {
            if try Firmware.readSetting(camera, Firmware.usbMode) != usbMode {
                try Firmware.writeSetting(camera, Firmware.usbMode, usbMode)
            }
            applied.usbMode = usbMode
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
        // Written while recording, these do nothing until the next
        // recording, and the camera restarts when that one stops; `stream`
        // stops the recording to change them.
        if !recording { try applyMovieSettings(camera, &applied) }
        if Date().timeIntervalSince(applied.batteryChecked) >= 30 {
            applied.batteryChecked = Date()
            let level = try Firmware.battery(camera)
            Task { @MainActor in
                // The camera only reports a few steps; log each new one.
                if level != self.battery { log.notice("Camera battery reads \(level, privacy: .public)") }
                self.battery = level
            }
        }
        // Focus holds the shutter button half down until the picture
        // settles, and keeps streaming meanwhile.
        // After the recording restarts, such as to switch autofocus, it waits
        // for the picture to come back, so the camera is recording again.
        if focusRequested.value {
            if !clearBusyOnFrame.value {
                focusRequested.value = false
                if !applied.focus.active {
                    try Firmware.startFocus(camera)
                    applied.focus.start()
                }
            }
        } else if applied.focus.active && applied.focus.done {
            applied.focus.stop()
            try Firmware.endFocus(camera)
            Task { @MainActor in self.focusing = false }
        }
    }

    /// Writes the movie settings if they've changed. Only while the camera
    /// isn't recording.
    private nonisolated func applyMovieSettings(_ camera: Camera, _ applied: inout Applied) throws {
        let movie = movieWanted.value
        guard applied.movie != movie else { return }
        for (setting, value) in movie.values {
            try Firmware.writeSetting(camera, setting, value)
        }
        applied.movie = movie
        log.notice("Movie settings: \(movie.description, privacy: .public)")
    }

    /// Whether anything wants video: an app using the Mark One camera, or
    /// the preview in Mark One's panel.
    private nonisolated func wanted() -> Bool {
        Preview.shared.visible || CameraSink.inUse()
    }

    /// Records while an app uses the Mark One camera, until the camera goes away.
    private nonisolated func serve(_ camera: Camera, to sink: CameraSink, frameList: Bool) throws {
        var applied = Applied()
        // Counting the camera's key events tells when someone is using its
        // own buttons and dials. Without it, the screen just goes off.
        var countsKeys = false
        do {
            countsKeys = try Firmware.countKeys(camera)
            if !countsKeys { log.notice("Can't count the camera's key events (unexpected code, or an older version's counter until the camera's switched off and on); its screen goes off every 30 s regardless") }
        } catch {
            log.notice("Can't count the camera's key events (\(error.localizedDescription, privacy: .public)); its screen goes off every 30 s regardless")
        }
        while !stopRequested.value {
            report("Ready. Pick “Mark One” as the camera in a video app.", .ready, card: "Starting the camera…")
            try Firmware.setScreen(camera, false)
            var screenChecked = Date(), keysChecked = Date(), lastKey = Date.distantPast
            var screenOn = false
            var keys = countsKeys ? try? Firmware.keyEvents(camera) : nil
            while !wanted() {
                if stopRequested.value { return }
                if installImage.value != nil { throw PipelineInterrupt.install }
                if !camera.connected { throw CameraError.disconnected }
                let focusing = applied.focus.active
                try updateControls(camera, &applied)
                // Mark One's own half press counts too, such as letting go
                // of one when a call ended mid-focus: start counting after it.
                if countsKeys && applied.focus.active != focusing { keys = try? Firmware.keyEvents(camera) }
                // A button or dial turns the screen on, since the camera
                // doesn't while Mark One has it off, so someone can use the
                // camera's own menus.
                if countsKeys && Date().timeIntervalSince(keysChecked) >= 0.5 {
                    keysChecked = Date()
                    // Until a read works, the first one is only the starting point.
                    if let now = try? Firmware.keyEvents(camera) {
                        if let before = keys, now != before {
                            lastKey = Date()
                            if !screenOn {
                                try? Firmware.setScreen(camera, true)
                                screenOn = true
                            }
                        }
                        keys = now
                    }
                }
                // The camera also turns its screen back on by itself while
                // it waits, so keep turning it off every 30 seconds, once
                // nothing's been pressed for 30 seconds. A lit screen isn't
                // worth giving up the camera over, so a failure here doesn't
                // throw.
                if Date().timeIntervalSince(screenChecked) >= 30 && Date().timeIntervalSince(lastKey) >= 30 {
                    screenChecked = Date()
                    try? Firmware.setScreen(camera, false)
                    screenOn = false
                }
                Diagnostics.heartbeat("Ready, and the camera answered \(Int(Date().timeIntervalSince(applied.batteryChecked))) s ago")
                Thread.sleep(forTimeInterval: 0.25)
            }
            // Someone used the camera's buttons, and may have left one of
            // its menus open, where it ignores REC.
            try stream(camera, to: sink, frameList: frameList, closeMenus: lastKey != .distantPast, applied: &applied)
        }
    }

    /// When to restart a recording: well before the movie writer's 2-hour
    /// limit. There's no 4 GB limit: with a card in, a recording ran
    /// past 4.5 GB and 37 minutes without a restart (2026-11-11).
    nonisolated static let restartTime: TimeInterval = 100 * 60
    /// The longest the last picture is held while a recording restarts.
    nonisolated static let restartFreeze: TimeInterval = 30

    /// Records and streams until nothing has wanted video for `grace`.
    private nonisolated func stream(_ camera: Camera, to sink: CameraSink, frameList: Bool, closeMenus: Bool, applied: inout Applied) throws {
        // Apple's hardware decoder needs revision 3's exact frames.
        let decoder: VideoDecoder = (frameList ? HardwareDecoder() : nil) ?? FrameDecoder()
        log.notice("Decoding with \(decoder is HardwareDecoder ? "Apple's hardware decoder" : "libavcodec", privacy: .public)")
        var shown = 0
        var last: CVPixelBuffer?
        var decoded = false
        var freeze: Freeze?
        let focus = applied.focus
        decoder.onFrame = { [weak self] buffer in
            if let self, self.clearBusyOnFrame.value { self.setBusy(nil) }
            if let restart = freeze {
                restart.stop()
                log.notice("Video back \(Date().timeIntervalSince(restart.started), format: .fixed(precision: 2), privacy: .public) s after restarting the recording")
                freeze = nil
            }
            focus.measure(buffer)
            // The camera's picture replaces the status card from here.
            if shown == 0 { self?.card.show(nil) }
            sink.send(buffer)
            Preview.shared.show(buffer)
            last = buffer
            decoded = true
            shown += 1
        }
        let streamer = Streamer(camera: camera, frameList: frameList)
        streamer.onLostTrack = { log.notice("\($0, privacy: .public)") }
        var since = Date(), lastUsed = Date(), lastChecked = Date()
        var received = 0, failuresBefore = 0, droppedBefore = sink.dropped
        var lastReceived = Date(), lastRecordingCheck = Date()
        var recordedBytes = 0
        var client: pid_t?
        let capture = UserDefaults.standard.bool(forKey: "SaveCapture") ? Capture() : nil
        // Seconds between restarts, for testing them: defaults write
        // com.superhighfives.markone RestartAfter 60
        let restartForTesting = UserDefaults.standard.double(forKey: "RestartAfter")
        report("Starting to record…", .streaming)
        setBusy("Starting the camera…")
        try Firmware.setScreen(camera, true)
        if closeMenus { try Firmware.closeMenus(camera) }
        try applyMovieSettings(camera, &applied)
        try Firmware.setRecording(camera, true)
        var recordingSince = Date()
        // Focus once the first picture is in: updateControls waits for it
        // while "Starting the camera…" is up.
        if focusOnStartWanted.value && !continuousWanted.value {
            Task { @MainActor in if self.state == .streaming && !self.focusing { self.focus() } }
        }
        defer {
            freeze?.stop()
            // Quitting keeps "Stopping the camera…" up until Mark One is gone.
            if !stopRequested.value { setBusy(nil) }
            showClient(nil)
            if camera.connected {
                report("Stopping the recording…")
                try? Firmware.setRecording(camera, false)
            }
        }
        while !stopRequested.value {
            if installImage.value != nil { throw PipelineInterrupt.install }
            let started = Date()
            sink.flush()
            let frames = try streamer.poll()
            let polled = Date()
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
                recordedBytes += frame.count
                let before = decoder.failures
                decoded = false
                decoder.decode(frame)
                capture?.add(frame, failed: decoder.failures != before)
                // While the decoder waits for a keyframe, repeat the
                // last picture so apps see a short freeze, not a gap.
                if !decoded, let last { sink.send(last) }
            }
            let decodedAt = Date()
            if frames.isEmpty { Thread.sleep(forTimeInterval: 0.003) }
            // A recording that reaches the movie writer's 2-hour limit
            // hangs the camera's recorder until it's switched off. Stop and
            // start well before.
            let recordedFor = Date().timeIntervalSince(recordingSince)
            if recordedFor >= Pipeline.restartTime
                || (restartForTesting > 0 && recordedFor >= restartForTesting) {
                let rate = Double(recordedBytes) * 8 / recordedFor / 1_000_000
                log.notice("Restarting the recording after \(recordedFor / 60, format: .fixed(precision: 1), privacy: .public) minutes and \(Double(recordedBytes) / 1_073_741_824, format: .fixed(precision: 2), privacy: .public) GB (\(rate, format: .fixed(precision: 1), privacy: .public) Mbps).")
                // The camera takes about 2 s to start recording again, and
                // could take longer. Past 3 s the extension shows its gray
                // placeholder, which ends recordings in apps such as
                // QuickTime, so hold the last picture meanwhile.
                if let last { freeze = Freeze(last, to: sink, for: Pipeline.restartFreeze) }
                try Firmware.setRecording(camera, false)
                try Firmware.setRecording(camera, true)
                recordingSince = Date()
                recordedBytes = 0
            }
            // If video stops for anything else, such as the REC button,
            // start recording again.
            if Date().timeIntervalSince(lastReceived) > 2, Date().timeIntervalSince(lastRecordingCheck) > 2 {
                lastRecordingCheck = Date()
                if try !Firmware.isRecording(camera) {
                    let minutes = Date().timeIntervalSince(recordingSince) / 60
                    log.notice("The camera stopped recording after \(minutes, format: .fixed(precision: 2), privacy: .public) minutes. Starting again.")
                    try Firmware.setRecording(camera, true)
                    recordingSince = Date()
                    recordedBytes = 0
                }
            }
            // The camera reads the movie settings when a recording starts,
            // so restart it, holding the last picture meanwhile.
            if applied.movie != movieWanted.value, Date().timeIntervalSince(movieChanged.value) >= 2 {
                log.notice("Restarting the recording to change the movie settings")
                setBusy("Changing the camera’s settings…")
                if let last {
                    freeze?.stop()
                    freeze = Freeze(last, to: sink, for: Pipeline.restartFreeze)
                }
                try Firmware.setRecording(camera, false)
                try applyMovieSettings(camera, &applied)
                try Firmware.setRecording(camera, true)
                recordingSince = Date()
                recordedBytes = 0
            }
            let checkedAt = Date()
            try updateControls(camera, &applied, recording: true)
            let controlledAt = Date()
            defer {
                // Log any slow pass through the loop, to find the gaps' cause.
                let total = Date().timeIntervalSince(started)
                if total > 0.15 {
                    let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                    log.notice("Slow pass: \(Int(total * 1000), privacy: .public) ms (poll \(ms(started, polled), privacy: .public) ms, \(streamer.lastReads, privacy: .public) reads, \(streamer.lastBytes / 1024, privacy: .public) KB; decode \(frames.count, privacy: .public) frames \(ms(polled, decodedAt), privacy: .public) ms; recording check \(ms(decodedAt, checkedAt), privacy: .public) ms; controls \(ms(checkedAt, controlledAt), privacy: .public) ms; rest \(ms(controlledAt, Date()), privacy: .public) ms)")
                }
            }
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
                if decoder.failures > failuresBefore {
                    log.notice("\(decoder.failures - failuresBefore, privacy: .public) frames failed to decode")
                }
                if sink.dropped > droppedBefore {
                    log.notice("\(sink.dropped - droppedBefore, privacy: .public) frames dropped on the way to the camera extension")
                }
                droppedBefore = sink.dropped
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
/// files go in ~/Library/Caches.
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

/// Sends one picture to the camera extension 30 times a second on its own
/// thread, until stopped or for at most `limit` seconds, so apps see a
/// frozen picture while the pipeline is busy restarting the camera.
private final class Freeze {
    private let queue = DispatchQueue(label: "com.superhighfives.markone.freeze")
    private let timer: DispatchSourceTimer
    let started = Date()

    init(_ picture: CVPixelBuffer, to sink: CameraSink, for limit: TimeInterval) {
        let until = Date().addingTimeInterval(limit)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler {
            guard Date() < until else { return timer.cancel() }
            sink.send(picture)
        }
        timer.resume()
        self.timer = timer
    }

    /// Stops sending. No picture goes out after this returns.
    func stop() {
        timer.cancel()
        queue.sync {}
    }
}

#if DEBUG
extension Pipeline {
    /// Shows a made-up camera, for the screenshots Snapshots takes.
    func pretend(_ state: State = .waiting, status: String, problem: Problem? = nil, firmware: CameraFirmware? = nil,
                 battery: Int? = nil, framesPerSecond: Double = 0, activeApp: String? = nil, install: InstallProgress? = nil,
                 reportsOlderVersion: Bool = false) {
        self.state = state
        self.status = status
        self.problem = problem
        self.firmware = firmware
        self.battery = battery
        self.framesPerSecond = framesPerSecond
        self.activeApp = activeApp
        self.install = install
        self.reportsOlderVersion = reportsOlderVersion
    }
}
#endif
