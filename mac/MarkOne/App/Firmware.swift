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
        let pcMode = try camera.run(read32, 0, 0, 0x605F_0D3C).0
        try camera.run(0x7EDD_55BA, 2, 50, pcMode, 1)      // notification 50: camera control
        try camera.poke(keyStub, keyCode)
    }

    /// asm/key.s: puts a key event on the camera's key queue, as a button
    /// press does. Placed over console-only code, after asm/post.s.
    static let keyStub = UInt32(0x7EAB_0380)
    static let keyCode = Data(hex: "f8fef8dd9818caff0020df0008cb")
    /// The REC button ("Cut2" in the firmware's key table).
    static let recordButton = UInt32(0x1209)
    /// The shooting API's sequence state: 0x10 while a movie records.
    static let sequence = UInt32(0x602B_1FF4)

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
            "The camera's firmware isn't the one Mark One expects (\(name)). It needs E-M5 firmware 2.3 with the usb-tools patch."
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
