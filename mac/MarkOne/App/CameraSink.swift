// Sends frames to the Mark One camera extension's sink stream, which passes
// them to whichever apps use the camera. The same as Feed/main.swift, but
// for frames decoded in the app.

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

final class CameraSink {
    static let deviceUID = "5B2F6E1C-9A3D-4C8E-B0F1-4D2A7C6E8B10"   // see Extension/Provider.swift

    private let device: CMIODeviceID
    private let stream: CMIOStreamID
    private let queue: CMSimpleQueue

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

    /// Queues one frame, dropping it if the extension hasn't taken the last one.
    func send(_ buffer: CVPixelBuffer) {
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
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
        case .notInstalled: "The Mark One camera isn't installed yet. Click Install camera."
        case .cantOpen: "Couldn't open the Mark One camera's input."
        }
    }
}
