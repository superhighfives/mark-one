// A low-latency viewer for the camera's live video.
//
//   uv run scripts/stream.py --raw | mac/viewer/viewer
//
// Reads raw 1920x1080 NV12 frames (full range, BT.601, as stream.py --raw
// writes them) from stdin and shows each one as soon as it arrives, with
// no playback clock or queue. Apple's hardware decoder can't decode this
// camera's H.264, so stream.py decodes in software and this only displays.
//
// Build: swiftc -O -o mac/viewer/viewer mac/viewer/main.swift

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

let width = 1920
let height = 1080
let frameBytes = width * height * 3 / 2

final class Display {
    let layer = AVSampleBufferDisplayLayer()
    private var pool: CVPixelBufferPool?

    init() {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    /// Shows one NV12 frame.
    func show(_ frame: Data) {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        frame.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let planes = [(offset: 0, rows: height), (offset: width * height, rows: height / 2)]
            for (index, plane) in planes.enumerated() {
                let dst = CVPixelBufferGetBaseAddressOfPlane(buffer, index)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
                for row in 0..<plane.rows {
                    memcpy(dst + row * stride, src.baseAddress! + plane.offset + row * width, width)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // The camera's stream says BT.601 (matrix, primaries and transfer 6).
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample
        else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.sampleBufferRenderer.enqueue(sample)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let display = Display()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "E-M5"
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        // A layer-hosting view: set the layer before turning layers on.
        let view = NSView()
        display.layer.videoGravity = .resizeAspect
        display.layer.backgroundColor = NSColor.black.cgColor
        view.layer = display.layer
        view.wantsLayer = true
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Thread { self.readFrames() }.start()
    }

    /// Reads whole frames from stdin and shows only the newest one, so a
    /// slow moment never builds up a queue.
    func readFrames() {
        let input = FileHandle.standardInput
        var pending = Data()
        let lock = NSLock()
        var latest: Data?
        while true {
            let chunk = input.readData(ofLength: frameBytes - pending.count)
            if chunk.isEmpty { break }
            pending.append(chunk)
            guard pending.count == frameBytes else { continue }
            lock.lock()
            let idle = latest == nil
            latest = pending
            lock.unlock()
            pending = Data()
            if idle {
                DispatchQueue.main.async {
                    lock.lock()
                    let frame = latest
                    latest = nil
                    lock.unlock()
                    if let frame { self.display.show(frame) }
                }
            }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
