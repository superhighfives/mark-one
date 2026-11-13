// Sends frames to the Mark One camera extension's sink stream, which passes
// them to whichever apps use the camera. The same as Feed/main.swift, but
// for frames decoded in the app.

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

final class CameraSink {
    static let deviceUID = "5B2F6E1C-9A3D-4C8E-B0F1-4D2A7C6E8B10"   // see Extension/Provider.swift

    /// The extension's "used" property: "1" while an app uses the camera.
    static let inUseSelector = 0x7573_6564
    /// The extension's "clnt" property: the process ID of the app that last
    /// started using the camera, or "" when none is.
    static let clientSelector = 0x636C_6E74

    private let device: CMIODeviceID
    private let stream: CMIOStreamID
    private let queue: CMSimpleQueue
    /// A frame that arrived while the queue was full, sent as soon as the
    /// extension takes the one before. The extension asks about 26 ms after
    /// each frame, so frames that arrive together go out evenly spaced
    /// instead of all but the first being dropped.
    private var waiting: CVPixelBuffer?
    /// Frames dropped because two arrived while the queue was full.
    private(set) var dropped = 0
    /// Frames can come from the pipeline and from a `Freeze` at once.
    private let lock = NSLock()

    /// Opens the sink, waiting up to five seconds for the extension's device.
    init() throws {
        var allow: UInt32 = 1
        var addr = CameraSink.address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
        var found: (CMIODeviceID, CMIOStreamID)?
        for _ in 0..<50 where found == nil {
            for device in CameraSink.objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            where CameraSink.string(of: device, kCMIODevicePropertyDeviceUID) == CameraSink.deviceUID {
                for stream in CameraSink.objectIDs(of: device, kCMIODevicePropertyStreams)
                where CameraSink.string(of: stream, kCMIOObjectPropertyName)?.hasSuffix(".Sink") == true {
                    found = (device, stream)
                }
            }
            if found == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard let (device, stream) = found else { throw SinkError.notInstalled }
        var queueRef: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queueRef) == 0, let queueRef else {
            throw SinkError.cantOpen
        }
        self.device = device
        self.stream = stream
        self.queue = queueRef.takeRetainedValue()
        guard CMIODeviceStartStream(device, stream) == 0 else { throw SinkError.cantOpen }
    }

    deinit {
        CMIODeviceStopStream(device, stream)
    }

    /// Whether any app is using the Mark One camera. False if the camera
    /// extension isn't installed.
    static func inUse() -> Bool {
        guard let device = installedDevice() else { return false }
        return string(of: device, inUseSelector) == "1"
    }

    /// The process using the Mark One camera, when the extension knows it.
    static func client() -> pid_t? {
        guard let device = installedDevice(), let text = string(of: device, clientSelector),
              let pid = pid_t(text), pid != getpid() else { return nil }
        return pid
    }

    /// Whether the Mark One camera exists, meaning its extension is running.
    /// In a process that started before the extension was switched on, it
    /// stays false (see "Processes don't see the camera come back" in
    /// NOTES.md).
    static var available: Bool { installedDevice() != nil }

    /// Whether any camera this process can see is in use, by any app.
    static func anyInUse() -> Bool {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).contains { device in
            var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == 0
                && running != 0
        }
    }

    private static func installedDevice() -> CMIODeviceID? {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first { string(of: $0, kCMIODevicePropertyDeviceUID) == deviceUID }
    }

    /// Queues one frame, or holds it back until the extension has taken the
    /// last one. Only the newest frame is held back.
    func send(_ buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        sendWaiting()
        if waiting == nil, enqueue(buffer) { return }
        if waiting != nil { dropped += 1 }
        waiting = buffer
    }

    /// Sends the frame held back, if the extension has room for it. Call often.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        sendWaiting()
    }

    private func sendWaiting() {
        if let frame = waiting, enqueue(frame) { waiting = nil }
    }

    private func enqueue(_ buffer: CVPixelBuffer) -> Bool {
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return false }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return true }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
        return true
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids)
        return ids
    }

    private static func string(of object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                        &used, &value) == 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

enum SinkError: LocalizedError {
    case notInstalled, cantOpen

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Waiting for the Mark One camera to start…"
        case .cantOpen: "Waiting for the Mark One camera's input to open…"
        }
    }
}
