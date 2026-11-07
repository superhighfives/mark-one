// markone-feed: sends the E-M5's video to the Mark One virtual camera.
//
//   uv run scripts/stream.py --raw | markone-feed
//
// Reads raw 1920x1080 NV12 frames (full range, BT.601) from stdin and puts
// each one in the sink stream of the Mark One camera extension, which
// passes it to whichever apps use the camera. Needs the extension
// installed (open Mark One.app and click Install camera).

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

let width = 1920
let height = 1080
let frameBytes = width * height * 3 / 2
let deviceUID = "5B2F6E1C-9A3D-4C8E-B0F1-4D2A7C6E8B10"   // see Extension/Provider.swift

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("markone-feed: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func objectIDs(of object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids)
    return ids
}

func string(of object: CMIOObjectID, _ selector: Int) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == 0, let value else { return nil }
    return value.takeRetainedValue() as String
}

/// The Mark One device and its sink stream. Devices from camera extensions
/// can take a moment to appear, so this waits for up to five seconds.
func findSink() -> (device: CMIODeviceID, stream: CMIOStreamID) {
    // Let this process see devices from camera extensions.
    var allow: UInt32 = 1
    var addr = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                              UInt32(MemoryLayout<UInt32>.size), &allow)
    for _ in 0..<50 {
        for device in objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        where string(of: device, kCMIODevicePropertyDeviceUID) == deviceUID {
            for stream in objectIDs(of: device, kCMIODevicePropertyStreams)
            where string(of: stream, kCMIOObjectPropertyName)?.hasSuffix(".Sink") == true {
                return (device, stream)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("the Mark One camera isn't installed. Open Mark One.app and click Install camera.")
}

let (device, stream) = findSink()

var queueRef: Unmanaged<CMSimpleQueue>?
guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queueRef) == 0, let queueRef else {
    fail("couldn't open the camera's input")
}
let queue = queueRef.takeRetainedValue()
guard CMIODeviceStartStream(device, stream) == 0 else { fail("couldn't start the camera's input") }

var pool: CVPixelBufferPool?
let attributes: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelBufferWidthKey: width,
    kCVPixelBufferHeightKey: height,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
]
CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)

/// Wraps one NV12 frame as a sample buffer stamped with the current time.
func sample(from frame: Data) -> CMSampleBuffer? {
    var buffer: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    frame.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        for (plane, offset, rows) in [(0, 0, height), (1, width * height, height / 2)] {
            let dst = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<rows {
                memcpy(dst + row * stride, src.baseAddress! + offset + row * width, width)
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    // The camera's stream says BT.601 (matrix, primaries and transfer 6).
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

    var format: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                    decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard let format else { return nil }
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                             sampleTiming: &timing, sampleBufferOut: &sample)
    return sample
}

let input = FileHandle.standardInput
var pending = Data()
var sent = 0, dropped = 0
var since = Date()
while true {
    let chunk = input.readData(ofLength: frameBytes - pending.count)
    if chunk.isEmpty { break }
    pending.append(chunk)
    guard pending.count == frameBytes else { continue }
    defer { pending = Data() }
    // The queue holds one frame; if the extension hasn't taken the last
    // one yet, drop this one rather than fall behind.
    guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue), let sample = sample(from: pending) else {
        dropped += 1
        continue
    }
    CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    sent += 1
    if Date().timeIntervalSince(since) >= 10 {
        FileHandle.standardError.write("markone-feed: \(sent / 10) frames per second, \(dropped) dropped\n".data(using: .utf8)!)
        sent = 0
        dropped = 0
        since = Date()
    }
}
CMIODeviceStopStream(device, stream)
