// Decodes the camera's H.264 frames with libavcodec.
//
// VideoToolbox's software decoder rejects about 1% of this camera's frames
// (and its hardware decoder all of them; see NOTES.md), while libavcodec
// decodes every one. Each frame comes out as soon as it goes in: the
// stream has no reordering, and low-delay mode stops libavcodec from
// holding frames back. Output is full-range NV12 in IOSurface-backed
// pixel buffers, the camera extension's format.

import CoreVideo
import Foundation

final class FrameDecoder {
    private let context: UnsafeMutablePointer<AVCodecContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private(set) var failures = 0
    var onFrame: ((CVPixelBuffer) -> Void)?

    init() {
        let codec = avcodec_find_decoder(AV_CODEC_ID_H264)
        let context = avcodec_alloc_context3(codec)!
        context.pointee.flags |= Int32(AV_CODEC_FLAG_LOW_DELAY)
        context.pointee.thread_count = 1                 // frame threads would add a frame of delay each
        avcodec_open2(context, codec, nil)
        self.context = context
        packet = av_packet_alloc()
        frame = av_frame_alloc()
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
    }

    /// Decodes one frame: Annex B NAL units, starting with an access unit delimiter.
    func decode(_ data: Data) {
        guard av_new_packet(packet, Int32(data.count)) == 0 else { return }
        data.copyBytes(to: packet.pointee.data, count: data.count)
        let sent = avcodec_send_packet(context, packet)
        av_packet_unref(packet)
        if sent < 0 { failures += 1 }
        while avcodec_receive_frame(context, frame) == 0 {
            if frame.pointee.decode_error_flags != 0 { failures += 1 }
            if let buffer = pixelBuffer(frame.pointee) { onFrame?(buffer) }
            av_frame_unref(frame)
        }
    }

    /// Copies a planar 4:2:0 frame into an NV12 pixel buffer.
    private func pixelBuffer(_ frame: AVFrame) -> CVPixelBuffer? {
        let format = frame.format
        guard format == AV_PIX_FMT_YUVJ420P.rawValue || format == AV_PIX_FMT_YUV420P.rawValue else { return nil }
        let width = Int(frame.width), height = Int(frame.height)
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let (y, ySource) = (Int(frame.linesize.0), frame.data.0!)
        for row in 0..<height {
            (luma + row * lumaStride).update(from: ySource + row * y, count: width)
        }

        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let (u, uSource, v, vSource) = (Int(frame.linesize.1), frame.data.1!, Int(frame.linesize.2), frame.data.2!)
        for row in 0..<(height + 1) / 2 {
            let out = chroma + row * chromaStride
            let cb = uSource + row * u, cr = vSource + row * v
            for column in 0..<(width + 1) / 2 {
                out[2 * column] = cb[column]
                out[2 * column + 1] = cr[column]
            }
        }
        return buffer
    }
}
