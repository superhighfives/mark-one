// What Mark One changes in the camera's running firmware, all in memory: a
// restart undoes it. Addresses are for E-M5 firmware 2.3 with the
// usb-tools patch; NOTES.md explains each one.

import CryptoKit
import Foundation

/// Olympus's code at an address, known only by its length and SHA-256, so
/// the app can check it's there without carrying a copy.
struct StockCode {
    let count: Int
    let sha256: String

    func matches(_ data: Data) -> Bool {
        data.count == count && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
}

enum Firmware {
    /// Two tiny helpers that read and write through the CPU cache, which USB
    /// transfers can't reach, placed in the unused end of the usb-tools
    /// handler space: `mov (a0),d0; rets` and `mov d0,(a0); mov (a0),d0; rets`.
    static let read32 = UInt32(0x7EAA_AB74)
    static let write32 = UInt32(0x7EAA_AB7A)
    static let helpers = Data([0x70, 0xF0, 0xFC, 0xCB, 0xCB, 0xCB, 0x60, 0x70, 0xF0, 0xFC, 0xCB, 0xCB])

    /// {address: (stock code, patched bytes)}. See RUNTIME_PATCHES in scripts/ptp.py.
    static let patches: [(name: String, address: UInt32, stock: StockCode, patched: String)] = [
        ("card writes", 0x7E7A_75B2, StockCode(count: 8, sha256: "a992a1cc0e34ee17c87249d72320405cffaa92e8605577e7b9f827613ec807a7"), "84cbcbcbcbcbcb83"),
        ("card writes", 0x7E7C_04CA, StockCode(count: 8, sha256: "360186c7f9ecda61e3f9127d90ebc33fcee04c4315488f233438cb3d415b5be4"), "84cbcbcbcbcbcb82"),
        ("time limit", 0x7E7B_BF88, StockCode(count: 4, sha256: "9a53ef45d36df0fd6f90f388d1696df8db514faf8ce5f184d4e68ab561db3856"), "0427ff7f"),
        ("time limit", 0x7E7B_BFBC, StockCode(count: 12, sha256: "5c7993277f758597d2e77926f35759decab9140c60a08c80b6b1b227a5f73d6e"), "f1dc8283cbcbcbcbcbcbcb5c"),
        ("muxer time limit", 0x7E7A_7C50, StockCode(count: 8, sha256: "888ec7b316e4e6c6f6e5ff6d577f4576949bf4ca7d79363ea7b74473d4853257"), "18fccc00dd6d00ca"),
    ]

    /// Puts the camera in shooting mode with USB connected, with movies that
    /// don't write the card and have no time limit. See shoot() in ptp.py.
    static func prepare(_ camera: Camera) throws {
        try camera.poke(read32, helpers)
        for patch in patches {
            let patched = Data(hex: patch.patched)
            let current = try camera.peek(patch.address, patch.stock.count)
            if patch.stock.matches(current) {
                try camera.poke(patch.address, patched)
            } else if current != patched {
                throw FirmwareError.unexpected(patch.name)
            }
        }
        // PC sub-state 0x6005 (MTP) uses 0x6004's event list, which handles
        // the "start camera control" events.
        try camera.run(write32, 0x7EEF_30EC, 0, 0x7EEF_375C)
        try camera.run(write32, 8, 0, 0x7EEF_3760)
        // Let the power switch turn the camera off: send its event to the
        // shooting app, as in normal shooting, instead of the app changer,
        // which drops it in this mode.
        try camera.run(write32, powerSwitchCheck, 0, powerSwitchEntry)
        let pcMode = try camera.run(read32, 0, 0, 0x605F_0D3C).0
        try camera.run(0x7EDD_55BA, 2, 50, pcMode, 1)      // notification 50: camera control
        try camera.poke(keyStub, keyCode)
        try camera.poke(buttonStub, buttonCode)
        // Unplugging mid-call: unlock the camera and stop recording (asm/unplug.s).
        try camera.poke(unplugStub, unplugCode)
        let callback = try camera.peek(callbackHook, callbackStock.count)
        if callbackStock.matches(callback) {
            try camera.poke(callbackHook, callbackJump)
        } else if callback != callbackJump {
            throw FirmwareError.unexpected("system event callback")
        }
    }

    /// asm/unplug.s: when the USB cable comes out, does what Mark One does
    /// when it lets go (unlock the buttons, free the mode dial, stop
    /// recording), which nothing else would. Placed over console-only code.
    static let unplugStub = UInt32(0x7EAA_F600)
    static let unplugCode = Data(hex: "a509c952f8fef0430047044208460cfca4bced5a60fce00000fffffc81bced5a60fcfff9bb0100fca4f41f2b60a010c91afccc09120002fcff490d0000fccc09120102fcff3d0d00005c005d045808590cf8fe10cff0f8fee4dcb89a3200")
    /// The system event callback (0x7edd910c) starts with a jump to the stub
    /// instead of `movm [d2,d3,a2,a3],(sp); add -28,sp`, which the stub runs.
    /// The next byte comes along unchanged, since writes have to be even.
    static let callbackHook = UInt32(0x7EDD_910C)
    static let callbackStock = StockCode(count: 6, sha256: "3e8fea91360178799dce3b020de404718accca5e25d09568f59ca80f34e8f4c1")
    static let callbackJump = Data(hex: "dcf464cdff93")

    /// The power switch's entry in the mode manager's event check table
    /// (0x7eeea834), and the stock handler that answers "not an app change".
    static let powerSwitchEntry = UInt32(0x7EEE_A8B0)
    static let powerSwitchCheck = UInt32(0x7EDC_726A)

    /// asm/key.s: puts a key event on the camera's key queue, as a button
    /// press does. Placed over console-only code, after asm/post.s.
    static let keyStub = UInt32(0x7EAB_0380)
    static let keyCode = Data(hex: "f8fef8dd9818caff0020df0008cb")
    /// asm/button.s: sends a key event through the key task's own send
    /// function, the way a real button press arrives.
    static let buttonStub = UInt32(0x7EAA_F5E0)
    static let buttonCode = Data(hex: "f8fef8ddba00f3ffc00cdf0008cb")
    /// The REC button ("Cut2" in the firmware's key table).
    static let recordButton = UInt32(0x1209)
    /// The shooting API's sequence state: 0x10 while a movie records.
    static let sequence = UInt32(0x602B_1FF4)

    /// Objects whose methods the firmware's own menus call. Each is a pointer
    /// to the object; the methods take it in a0.
    static let settingsObject = UInt32(0x602B_2598)    // OlyHfwUserSettingManager
    static let commonObject = UInt32(0x602B_243C)      // CameraCommon
    static let setSetting = UInt32(0x7EAD_1020)        // d0 = setting, d1 = 0, a1 = value
    static let setModeDial = UInt32(0x7EAA_71CD)       // d0 = dial state
    static let getModeDial = UInt32(0x7EAA_683F)
    static let backlight = UInt32(0x7EAA_6EBC)         // d0 = 1 on, 0 off
    static let undim = UInt32(0x7EAA_6BF6)
    static let cancelKeys = UInt32(0x7EAC_B1A9)        // d0 = count, a1 = list
    static let resetKeys = UInt32(0x7EAC_B21A)
    /// Set while the dial state comes from setModeDial instead of the dial.
    static let dialOverride = UInt32(0x605A_EDBC)
    static let movieDial = UInt32(5)
    static let getSetting = UInt32(0x7EAD_08AA)        // d0 = setting, a1 = where to put the value
    static let afTarget = UInt32(0x79)                 // 1-35, by columns; 18 is the center
    static let movieAFMode = UInt32(0x1B2)             // 0 single, 1 continuous, 2 manual
    /// A word for getSetting's answer, in the same console usage text as keyList.
    static let settingOut = UInt32(0x7EAA_F5F0)
    /// Where the list of locked controls goes: the usage text of the
    /// console's `sdk api cancelKeyEvent` command.
    static let keyList = UInt32(0x7EAA_F460)
    /// Every control but the power switch, the eye sensor, the two dials
    /// (exposure compensation) and a half press of the shutter button
    /// (focus). The full press and the movie button are locked too; Mark
    /// One's key stub reaches the key queue past this list.
    static let lockedKeys: [UInt32] = [48, 49, 52, 53, 56, 57, 60, 61, 64, 65, 68, 69, 72, 73, 76, 77,
                                       80, 81, 84, 85, 88, 89, 92, 93, 96, 97, 100, 101, 120, 121, 127, 128]

    static let whiteBalance = UInt32(0x0B)             // see Pipeline.WhiteBalance
    static let pictureMode = UInt32(0xAC)              // see Pipeline.PictureMode
    static let facePriority = UInt32(0x172)            // 0 off, 1 faces, 2-4 faces and eyes
    /// 0 Full HD Fine, 1 Full HD Normal, 2 HD Fine, 3 HD Normal, 4-5 AVI.
    static let movieQuality = UInt32(0x43)
    static let fullHDFine = UInt32(0)

    /// Camera settings Mark One changes and puts back afterwards.
    struct Saved: Codable {
        var movieAFMode: UInt32
        var whiteBalance: UInt32
        var pictureMode: UInt32
        var facePriority: UInt32
        var movieQuality: UInt32
    }

    /// Remembered on the Mac until they're back on the camera.
    static let pendingKey = "CameraSettingsToRestore"

    static func readSetting(_ camera: Camera, _ setting: UInt32) throws -> UInt32 {
        let settings = try camera.run(read32, 0, 0, settingsObject).0
        try camera.run(getSetting, setting, 0, settings, settingOut)
        return try camera.run(read32, 0, 0, settingOut).0
    }

    static func writeSetting(_ camera: Camera, _ setting: UInt32, _ value: UInt32) throws {
        let settings = try camera.run(read32, 0, 0, settingsObject).0
        try camera.run(setSetting, setting, 0, settings, value)
    }

    /// Sets the camera up the same way every time: movie mode whatever the
    /// mode dial says, the center focus point, and single autofocus, so the
    /// camera focuses only when asked instead of hunting mid-call (the
    /// panel's "Continuous autofocus" switches it back). Run after
    /// `prepare`; the camera takes a moment to switch to shooting. Returns
    /// the settings to restore with `releasePresets`.
    static func applyPresets(_ camera: Camera) throws -> Saved {
        let common = try camera.run(read32, 0, 0, commonObject).0
        let settings = try camera.run(read32, 0, 0, settingsObject).0
        for _ in 0..<20 {
            try camera.run(setModeDial, movieDial, 0, common)
            if try camera.run(getModeDial, 0, 0, common).0 == movieDial { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        try camera.run(setSetting, afTarget, 0, settings, 18)
        // If the camera went off while Mark One had it (switched off or
        // unplugged), it kept Mark One's settings, so the camera's own are the ones
        // saved last time.
        let saved = try Saved.pending ?? Saved(movieAFMode: readSetting(camera, movieAFMode),
                                               whiteBalance: readSetting(camera, whiteBalance),
                                               pictureMode: readSetting(camera, pictureMode),
                                               facePriority: readSetting(camera, facePriority),
                                               movieQuality: readSetting(camera, movieQuality))
        Saved.pending = saved
        // The stream Mark One decodes is 1080p; the camera reads this when a
        // recording starts.
        try writeSetting(camera, movieQuality, fullHDFine)
        try writeSetting(camera, movieAFMode, 0)
        return saved
    }

    /// Locks every control but the power switch, the dials and focusing, or
    /// unlocks them all.
    static func setControlsLocked(_ camera: Camera, _ locked: Bool) throws {
        try camera.run(resetKeys)
        guard locked else { return }
        for (index, key) in lockedKeys.enumerated() {
            try camera.run(write32, key, 0, keyList + UInt32(4 * index))
        }
        try camera.run(cancelKeys, UInt32(lockedKeys.count), 0, 0, keyList)
    }

    /// Hands the controls back: the mode dial and buttons work again and the
    /// screen is on.
    static func releasePresets(_ camera: Camera, _ saved: Saved) throws {
        try camera.run(resetKeys)
        try writeSetting(camera, movieAFMode, saved.movieAFMode)
        try writeSetting(camera, whiteBalance, saved.whiteBalance)
        try writeSetting(camera, pictureMode, saved.pictureMode)
        try writeSetting(camera, facePriority, saved.facePriority)
        try writeSetting(camera, movieQuality, saved.movieQuality)
        Saved.pending = nil
        let word = try camera.run(read32, 0, 0, dialOverride).0
        try camera.run(write32, word & 0xFFFF_0000, 0, dialOverride)
        try setScreen(camera, true)
    }

    /// Exposure compensation: 0x100 is one stop.
    static let exposureCompensation = UInt32(0x03)

    /// Sets exposure compensation in thirds of a stop. Works while recording.
    static func setBrightness(_ camera: Camera, _ thirds: Int) throws {
        let settings = try camera.run(read32, 0, 0, settingsObject).0
        let value = Int32((Double(thirds) * 256 / 3).rounded())
        try camera.run(setSetting, exposureCompensation, 0, settings, UInt32(bitPattern: value))
    }

    /// Turns the rear screen on at full brightness, or off.
    static func setScreen(_ camera: Camera, _ on: Bool) throws {
        let common = try camera.run(read32, 0, 0, commonObject).0
        try camera.run(backlight, on ? 1 : 0, 0, common)
        if on { try camera.run(undim, 0, 0, common) }
    }

    /// A half press of the shutter button ("Trg1" in the firmware's key table).
    static let halfPressKey = UInt32(0x0100)

    /// The key task's record of the shutter button: one byte each at
    /// 0x60501e98 to 0x60501e9b. When the button is pushed halfway, the key
    /// task (0x7e5ec962) sets 0x60501e99 and 0x60501e9b to 1 and sends the
    /// press event; when it's let go, it clears them and sends the release.
    static let shutterState = UInt32(0x6050_1E98)
    static let halfPressHeld = UInt32(0x0100_0100)

    /// Presses the shutter button halfway, which focuses, even while
    /// recording. While recording, the camera keeps checking whether the
    /// button is still down (0x7e5ebb4b, from 0x7eb75d93) and stops focusing
    /// once it isn't. That check reads the key task's record rather than
    /// the button itself, so mark the button as held there too.
    static func startFocus(_ camera: Camera) throws {
        let state = try camera.run(read32, 0, 0, shutterState).0
        try camera.run(write32, state | halfPressHeld, 0, shutterState)
        try camera.run(buttonStub, 0x0200_0000 | halfPressKey)
    }

    /// Switches movie autofocus between continuous and single (Focus only).
    static func setContinuousFocus(_ camera: Camera, _ on: Bool) throws {
        try writeSetting(camera, movieAFMode, on ? 1 : 0)
    }

    static func endFocus(_ camera: Camera) throws {
        try camera.run(buttonStub, 0x0201_0000 | halfPressKey)
        let state = try camera.run(read32, 0, 0, shutterState).0
        try camera.run(write32, state & ~halfPressHeld, 0, shutterState)
    }

    /// The battery level, 1 to 100, from the standard PTP property.
    /// The E-M5 reports it in coarse steps.
    static func battery(_ camera: Camera) throws -> Int {
        let data = try camera.send(0x1015, [0x5001], name: "the battery level").1
        guard let level = data.first else { throw CameraError.notFound }
        return Int(level)
    }

    /// Whether the camera has a card in. Without one it lists a single
    /// storage ID whose low half is 0, PTP's "no media".
    static func hasCard(_ camera: Camera) throws -> Bool {
        let data = try camera.send(0x1004, [], name: "the storage list").1
        guard data.count >= 4 else { return false }
        let count = Int(data.le(UInt32.self, at: 0))
        return (0..<count).contains { 4 + 4 * $0 + 4 <= data.count && data.le(UInt32.self, at: 4 + 4 * $0) & 0xFFFF != 0 }
    }

    static func isRecording(_ camera: Camera) throws -> Bool {
        try camera.run(read32, 0, 0, sequence).0 == 0x10
    }

    /// Presses and releases the REC button, then waits up to three seconds
    /// for recording to start or stop. Tries up to three times.
    static func setRecording(_ camera: Camera, _ on: Bool) throws {
        for _ in 0..<3 {
            if try isRecording(camera) == on { return }
            try camera.run(keyStub, 0x0200_0000 | recordButton)
            Thread.sleep(forTimeInterval: 0.5)
            try camera.run(keyStub, 0x0201_0000 | recordButton)
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.1)
                if try isRecording(camera) == on { return }
            }
        }
        throw FirmwareError.recording(on)
    }
}

enum FirmwareError: LocalizedError {
    case unexpected(String), recording(Bool)

    var errorDescription: String? {
        switch self {
        case .unexpected(let name):
            "The camera's firmware isn't the one Mark One expects (\(name)). It needs Mark One's firmware on an E-M5 (Mark I)."
        case .recording(let on):
            on ? "The camera didn't start recording. Check that it shows live view, then try again."
               : "The camera didn't stop recording. Press its REC button to stop."
        }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

extension Firmware.Saved {
    /// The camera's own settings while Mark One's are on it.
    static var pending: Self? {
        get {
            UserDefaults.standard.data(forKey: Firmware.pendingKey)
                .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Firmware.pendingKey)
        }
    }
}
