// A live preview of the camera in Mark One's menu bar panel. While the
// panel is open, it counts as an app using the camera, so the camera
// records and the preview shows what video apps would get.

import AVFoundation
import CoreMedia
import SwiftUI

final class Preview: @unchecked Sendable {
    static let shared = Preview()

    private let lock = NSLock()
    private var layers: [ObjectIdentifier: AVSampleBufferDisplayLayer] = [:]

    /// Whether a preview is on screen.
    var visible: Bool { lock.withLock { !layers.isEmpty } }

    fileprivate func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock { layers[ObjectIdentifier(layer)] = layer }
    }

    fileprivate func detach(_ layer: AVSampleBufferDisplayLayer) {
        _ = lock.withLock { layers.removeValue(forKey: ObjectIdentifier(layer)) }
        layer.flushAndRemoveImage()
    }

    /// Shows one decoded frame in every visible preview.
    func show(_ buffer: CVPixelBuffer) {
        let targets = lock.withLock { Array(layers.values) }
        guard !targets.isEmpty else { return }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async {
            for layer in targets {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sample)
            }
        }
    }
}

/// The preview's view. It asks for video only while its window is on screen.
struct PreviewView: NSViewRepresentable {
    /// Flips the picture left to right, like a mirror. Only the preview:
    /// video apps get the camera's picture as it is.
    var mirrored = false

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView() }
    func updateNSView(_ view: PreviewNSView, context: Context) { view.mirrored = mirrored }
}

final class PreviewNSView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
    }

    required init?(coder: NSCoder) { fatalError() }

    var mirrored = false {
        didSet {
            guard mirrored != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        // Bounds and position rather than frame, which isn't defined once
        // the layer is flipped.
        display.bounds = bounds
        display.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return Preview.shared.detach(display) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            self?.update()
        }
        update()
    }

    private func update() {
        if window?.occlusionState.contains(.visible) == true {
            Preview.shared.attach(display)
        } else {
            Preview.shared.detach(display)
        }
    }
}
