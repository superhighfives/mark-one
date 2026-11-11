// Decodes the camera's H.264 frames with libavcodec.
//
// Used for firmware before revision 3, whose frames Mark One can't cut
// exactly enough for Apple's decoder (see HardwareDecoder.swift), and when
// the hardware decoder fails. Each frame comes out as soon as it goes in: the
// stream has no reordering, and low-delay mode stops libavcodec from
// holding frames back. Output is full-range NV12 in IOSurface-backed
// pixel buffers, the camera extension's format.

import Accelerate
import CoreVideo
import Foundation

/// Turns the camera's H.264 frames into NV12 pixel buffers.
protocol VideoDecoder: AnyObject {
    /// Frames that failed to decode so far.
    var failures: Int { get }
    /// Called with each decoded picture, before `decode` returns.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// Decodes one frame: Annex B NAL units, starting with an access unit delimiter.
    func decode(_ data: Data)
}

final class FrameDecoder: VideoDecoder {
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

        // Interleave Cb and Cr into the NV12 chroma plane.
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        var planes = [vImage_Buffer(data: frame.data.1, height: vImagePixelCount((height + 1) / 2),
                                    width: vImagePixelCount((width + 1) / 2), rowBytes: Int(frame.linesize.1)),
                      vImage_Buffer(data: frame.data.2, height: vImagePixelCount((height + 1) / 2),
                                    width: vImagePixelCount((width + 1) / 2), rowBytes: Int(frame.linesize.2))]
        planes.withUnsafeMutableBufferPointer { planes in
            var sourcePlanes: [UnsafePointer<vImage_Buffer>?] = [UnsafePointer(planes.baseAddress!),
                                                                 UnsafePointer(planes.baseAddress! + 1)]
            var destinations: [UnsafeMutableRawPointer?] = [chroma, chroma + 1]
            vImageConvert_PlanarToChunky8(&sourcePlanes, &destinations, 2, 2,
                                          vImagePixelCount((width + 1) / 2), vImagePixelCount((height + 1) / 2),
                                          CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), vImage_Flags(kvImageNoFlags))
        }
        return buffer
    }
}
