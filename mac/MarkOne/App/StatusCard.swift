// While there's no picture from the camera, sends video apps a frame that
// says why, in place of the extension's dark gray placeholder. Google Meet
// reads that gray as "Camera might be blocked". This is drawn in the app,
// not the extension: a new extension build can lose the camera until the
// Mac restarts (TODO.md, "Extension updates").

import AppKit
import CoreVideo
import VideoToolbox

/// Thread-safe: everything it holds is used on `queue`.
final class StatusCard: @unchecked Sendable {
    /// Mirrors Pipeline.showStatusCard, for the card's own thread.
    let enabled = Flag()

    private let queue = DispatchQueue(label: "com.superhighfives.markone.status-card")
    private let timer: DispatchSourceTimer
    private var sink: CameraSink?
    private var text: String?
    private var frame: CVPixelBuffer?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // CameraSink.send drops frames while no app uses the camera, so
        // an app that starts it sees the extension's gray until the next
        // tick. Every 0.1 s keeps that short; it's the same buffer each time.
        timer.schedule(deadline: .now(), repeating: 0.1)
        self.timer = timer
        timer.setEventHandler { [unowned self] in
            guard enabled.value, let sink, let text else { return }
            if frame == nil { frame = StatusCard.draw(text) }
            if let frame { sink.send(frame) }
        }
        timer.resume()
    }

    /// Sends through `sink` from now on, or nowhere with nil.
    func attach(_ sink: CameraSink?) {
        queue.sync { self.sink = sink }
    }

    /// Shows `text`, or nothing with nil. Once this returns, no frame of
    /// the old text goes out, so the camera's first frame can follow a
    /// `show(nil)` with nothing in between.
    func show(_ text: String?) {
        queue.sync {
            guard text != self.text else { return }
            self.text = text
            frame = nil
        }
    }

    /// Dark text and a camera symbol on light gray, light enough that Meet
    /// doesn't call it blocked. Drawn the right way round: apps that
    /// mirror their own preview show it backwards there, but everyone else
    /// in the call can read it.
    private static func draw(_ text: String) -> CVPixelBuffer? {
        let width = 1920, height = 1080
        var bgra: CVPixelBuffer?, nv12: CVPixelBuffer?
        let surface = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, surface, &bgra)
        // The format the extension's stream takes.
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, surface, &nv12)
        guard let bgra, let nv12 else { return nil }
        CVPixelBufferLockBaseAddress(bgra, [])
        defer { CVPixelBufferUnlockBaseAddress(bgra, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        NSColor(white: 0.82, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let ink = NSColor(white: 0.18, alpha: 1)
        let symbol = NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 150, weight: .regular).applying(.init(paletteColors: [ink])))
        if let symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: (CGFloat(width) - size.width) / 2, y: 600, width: size.width, height: size.height))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: ink, .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(in: NSRect(x: 200, y: 300, width: 1520, height: 250))
        context.flush()

        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        return VTPixelTransferSessionTransferImage(session, from: bgra, to: nv12) == noErr ? nv12 : nil
    }
}
