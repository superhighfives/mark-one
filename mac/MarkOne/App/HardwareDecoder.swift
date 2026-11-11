// Decodes the camera's H.264 frames with Apple's hardware decoder
// (VideoToolbox), for cameras with revision 3 of Mark One's firmware.
//
// It needs frames cut exactly: a nonzero byte after a frame makes it
// reject the frame, and only revision 3's frame list gives exact sizes.
// The camera also adds new PPSs between keyframes, so each new one goes
// into a new format description that the running session accepts. Its
// pictures match libavcodec's exactly (see "Apple's decoder on exact
// frames" in NOTES.md). If the hardware decoder isn't available or keeps
// failing, frames go to libavcodec instead.

import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

private let log = Logger(subsystem: "com.superhighfives.markone", category: "decoder")

final class HardwareDecoder: VideoDecoder {
    private var sps: Data?
    private var pps: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// After a failure the session rejects every frame until it's made
    /// again, which needs a keyframe.
    private var waitingForKeyframe = false
    /// Where frames go once the hardware decoder has failed too often.
    private var fallback: FrameDecoder?
    private var ownFailures = 0
    var failures: Int { ownFailures + (fallback?.failures ?? 0) }
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Failures before handing over to libavcodec.
    private static let failureLimit = 5

    /// Nil when this Mac can't decode H.264 in hardware.
    init?() {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else { return nil }
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one frame: Annex B NAL units, starting with an access unit delimiter.
    func decode(_ data: Data) {
        if let fallback { return fallback.decode(data) }

        var slices = Data()
        var keyframe = false, newParameters = false
        for nal in HardwareDecoder.units(data) {
            switch nal[nal.startIndex] & 0x1f {
            case 7:
                if nal != sps { sps = nal; newParameters = true }
            case 8:
                guard let id = HardwareDecoder.ppsID(nal) else { break }
                if pps[id] != nal { pps[id] = nal; newParameters = true }
            case 1, 5:
                keyframe = keyframe || nal[nal.startIndex] & 0x1f == 5
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { slices.append(contentsOf: $0) }
                slices.append(nal)
            default:
                break                                      // delimiters and SEI
            }
        }
        guard !slices.isEmpty else { return }

        if newParameters || session == nil || (waitingForKeyframe && keyframe) {
            guard prepare(keyframe: keyframe) else { return }
        }
        if waitingForKeyframe { return }
        guard let session, let format, let sample = HardwareDecoder.sample(slices, format: format) else { return }

        var picture: CVImageBuffer?
        var result: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            result = status
            picture = image
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status == noErr, result == noErr, let picture {
            onFrame?(picture)
        } else {
            fail("decoding a frame failed (\(status), \(result))")
        }
    }

    /// Makes a format description from the parameter sets seen so far,
    /// and a session if the current one can't take it. False if there's
    /// nothing to decode with.
    private func prepare(keyframe: Bool) -> Bool {
        guard let sps, !pps.isEmpty else { return false }
        let sets = [sps] + pps.keys.sorted().map { pps[$0]! }
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: copy, count: set.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        var description: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4,
            formatDescriptionOut: &description) == noErr, let description else {
            fail("the camera's parameter sets were rejected")
            return false
        }
        format = description
        if let session, !waitingForKeyframe,
           VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            return true
        }
        // A new session has no reference frames, so it has to start at a keyframe.
        guard keyframe else { waitingForKeyframe = true; return true }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var made: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                                  decoderSpecification: specification as CFDictionary,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &made)
        guard status == noErr, let made else {
            fail("the hardware decoder couldn't start (\(status))")
            return false
        }
        VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = made
        waitingForKeyframe = false
        return true
    }

    private func fail(_ reason: String) {
        ownFailures += 1
        waitingForKeyframe = true
        log.notice("Hardware decoder: \(reason, privacy: .public)")
        guard ownFailures >= HardwareDecoder.failureLimit else { return }
        log.notice("Hardware decoder failed \(self.ownFailures, privacy: .public) times; using libavcodec")
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let decoder = FrameDecoder()
        decoder.onFrame = { [weak self] in self?.onFrame?($0) }
        fallback = decoder
    }

    /// A sample buffer holding one frame's slices, each with a 4-byte length.
    private static func sample(_ slices: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: slices.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: slices.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = slices.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: slices.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = slices.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// The NAL units in Annex B data, without their start codes.
    static func units(_ data: Data) -> [Data] {
        data.withUnsafeBytes { raw -> [Data] in
            guard let base = raw.baseAddress else { return [] }
            let code: [UInt8] = [0, 0, 1]
            var starts: [(code: Int, payload: Int)] = []
            var i = 0
            // memmem, not a byte loop: frames run to 100 KB or more.
            while i + 3 <= raw.count, let found = memmem(base + i, raw.count - i, code, 3) {
                let at = base.distance(to: UnsafeRawPointer(found))
                starts.append((at > 0 && raw[at - 1] == 0 ? at - 1 : at, at + 3))
                i = at + 3
            }
            return starts.indices.compactMap { k in
                let end = k + 1 < starts.count ? starts[k + 1].code : raw.count
                guard end > starts[k].payload else { return nil }
                return Data(raw[starts[k].payload..<end])
            }
        }
    }

    /// A PPS's ID: the first Exp-Golomb number after the NAL header.
    static func ppsID(_ nal: Data) -> Int? {
        guard nal.count > 1 else { return nil }
        var bits = BitReader([UInt8](nal.dropFirst()))
        return bits.ue()
    }
}
