// Talks to an E-M5 running the usb-tools firmware, through ImageCaptureCore.
//
// The firmware adds three PTP commands (see asm/usb.s): 0x9484 reads camera
// memory, 0x9485 writes it, and 0x9486 calls a function. ImageCaptureCore
// passes raw PTP commands to the camera with requestSendPTPCommand, which
// works in a sandboxed app and shares the camera with macOS's camera
// service instead of fighting it for the USB interface.

import Foundation
import ImageCaptureCore

enum CameraError: LocalizedError {
    case notFound, disconnected, session(Error?), command(UInt16, String), timeout

    var errorDescription: String? {
        switch self {
        case .notFound: "No E-M5 found. Connect it by USB and choose MTP on the camera."
        case .disconnected: "The camera was turned off or unplugged."
        case .session(let error): "Couldn't open the camera: \(error?.localizedDescription ?? "unknown error")."
        case .command(let code, let name): "The camera refused \(name) (\(String(format: "0x%04x", code)))."
        case .timeout: "The camera stopped responding."
        }
    }
}

/// One connected E-M5. All methods block, so call them off the main thread.
final class Camera: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    static let olympusVendorID = 0x07B4

    private let browser = ICDeviceBrowser()
    private var device: ICCameraDevice?
    private var transaction: UInt32 = 0
    private let found = DispatchSemaphore(value: 0)
    private let opened = DispatchSemaphore(value: 0)
    private var openError: Error?
    private let removed = Flag()
    var onDisconnect: (() -> Void)?

    /// Waits for the camera to appear, for as long as `keepWaiting` returns
    /// true, then opens a session.
    func connect(while keepWaiting: () -> Bool) throws {
        DispatchQueue.main.async {
            self.browser.delegate = self
            let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
            self.browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
            self.browser.start()
        }
        while found.wait(timeout: .now() + 0.5) == .timedOut {
            if !keepWaiting() { throw CameraError.notFound }
        }
        guard let device else { throw CameraError.disconnected }
        DispatchQueue.main.async { device.requestOpenSession() }
        guard opened.wait(timeout: .now() + 10) == .success else { throw CameraError.timeout }
        if let openError { throw CameraError.session(openError) }
    }

    /// False once the camera has been turned off or unplugged.
    var connected: Bool { !removed.value }

    /// Closes the session; `done` runs on the main thread once it's closed
    /// (or after two seconds if the camera doesn't answer).
    func disconnect(_ done: @escaping () -> Void = {}) {
        DispatchQueue.main.async {
            guard let device = self.device, device.hasOpenSession else {
                self.release()
                done()
                return
            }
            self.closed = done
            device.requestCloseSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.finishClose() }
        }
    }

    private var closed: (() -> Void)?

    private func finishClose() {
        guard let closed else { return }
        self.closed = nil
        release()
        closed()
    }

    /// Stops browsing and unhooks this object from ImageCaptureCore, which
    /// doesn't retain its delegates and would otherwise call into a freed
    /// object when the camera is unplugged or turned off later.
    private func release() {
        device?.delegate = nil
        browser.delegate = nil
        browser.stop()
    }

    /// Sends one PTP command and returns (response parameters, data from the camera).
    @discardableResult
    func send(_ code: UInt16, _ params: [UInt32], data out: Data? = nil, name: String) throws -> ([UInt32], Data) {
        guard let device else { throw removed.value ? CameraError.disconnected : CameraError.notFound }
        transaction &+= 1
        var command = Data()
        command.append(le: UInt32(12 + 4 * params.count))
        command.append(le: UInt16(1))                 // command block
        command.append(le: code)
        command.append(le: transaction)
        for p in params { command.append(le: p) }

        let done = DispatchSemaphore(value: 0)
        var received = Data(), response = Data(), failure: Error?
        device.requestSendPTPCommand(command, outData: out) { data, responseData, error in
            received = data
            response = responseData
            failure = error
            done.signal()
        }
        let answered = done.wait(timeout: .now() + 10) == .success
        // A camera that turns off mid-command answers with an empty
        // response, just before ImageCaptureCore reports it gone.
        if removed.value || (answered && failure == nil && response.count < 8) { throw CameraError.disconnected }
        guard answered else { throw CameraError.timeout }
        if failure != nil { throw CameraError.session(failure) }
        // Response container: length, type, code, transaction, parameters.
        let rcode = response.count >= 8 ? response.le(UInt16.self, at: 6) : 0
        guard rcode == 0x2001 else { throw CameraError.command(rcode, name) }
        let count = max(0, (response.count - 12) / 4)
        return ((0..<count).map { response.le(UInt32.self, at: 12 + 4 * $0) }, received)
    }

    /// The commands the camera lists in its device info (GetDeviceInfo).
    func operations() throws -> [UInt16] {
        let info = try send(0x1001, [], name: "the device info").1
        // Standard version, vendor extension ID and version, then the
        // vendor extension description (a PTP string) and functional mode.
        var offset = 8
        guard info.count > offset else { return [] }
        offset += 1 + 2 * Int(info[info.startIndex + offset]) + 2
        guard info.count >= offset + 4 else { return [] }
        let count = Int(info.le(UInt32.self, at: offset))
        offset += 4
        guard info.count >= offset + 2 * count else { return [] }
        return (0..<count).map { info.le(UInt16.self, at: offset + 2 * $0) }
    }

    /// USB transfers only reach the uncached view of RAM, 0x40000000 above the cached one.
    static func uncached(_ address: UInt32) -> UInt32 {
        (0x4000_0000..<0x8000_0000).contains(address) ? address + 0x4000_0000 : address
    }

    func peek(_ address: UInt32, _ length: Int) throws -> Data {
        try send(0x9484, [Camera.uncached(address), UInt32(length)], name: "a memory read").1
    }

    func poke(_ address: UInt32, _ bytes: Data) throws {
        try send(0x9485, [Camera.uncached(address)], data: bytes, name: "a memory write")
    }

    /// Calls a function (one that sets up its own stack frame) with d0, d1, a0, a1.
    @discardableResult
    func run(_ function: UInt32, _ d0: UInt32 = 0, _ d1: UInt32 = 0, _ a0: UInt32 = 0, _ a1: UInt32 = 0) throws -> (UInt32, UInt32) {
        let params = try send(0x9486, [function, d0, d1, a0, a1], name: "a function call").0
        return (params.first ?? 0, params.count > 1 ? params[1] : 0)
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard self.device == nil, let camera = device as? ICCameraDevice,
              camera.usbVendorID == Camera.olympusVendorID else { return }
        camera.delegate = self
        self.device = camera
        found.signal()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === self.device {
            device.delegate = nil
            self.device = nil
            removed.value = true
            onDisconnect?()
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        openError = error
        opened.signal()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        DispatchQueue.main.async { self.finishClose() }
    }
    func didRemove(_ device: ICDevice) {}

    // Required by ICCameraDeviceDelegate; unused.
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func le<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)) }
        return T(littleEndian: value)
    }
}
