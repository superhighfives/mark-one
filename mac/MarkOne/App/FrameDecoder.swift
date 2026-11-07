// Decodes the camera's H.264 frames with VideoToolbox's software decoder.
//
// The hardware decoder rejects every frame of this camera's stream (error
// -12909, bad data; see NOTES.md). The software decoder takes most frames,
// but a failure breaks the session, so after one it waits for the next
// keyframe (every 15 frames) and starts a new session.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class FrameDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: (sps: [UInt8], pps: [UInt8])?
    private var broken = true
    private(set) var failures = 0
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Decodes one frame: Annex B NAL units, starting with an access unit delimiter.
    func decode(_ frame: Data) {
        var sps: [UInt8]?, pps: [UInt8]?
        var units: [[UInt8]] = []
        for unit in FrameDecoder.nalUnits([UInt8](frame)) {
            switch unit[0] & 0x1F {
            case 7: sps = unit
            case 8: pps = unit; units.append(unit)       // the camera sends one with every frame
            case 9: break                                // access unit delimiter
            default: units.append(unit)
            }
        }
        let keyframe = units.contains { $0[0] & 0x1F == 5 }
        if keyframe, let sps, let pps, broken || parameterSets?.sps != sps {
            makeSession(sps: sps, pps: pps)
        }
        guard !broken, let session, let format, !units.isEmpty else { return }

        // AVCC: each NAL unit with a 4-byte big-endian length.
        var avcc = [UInt8]()
        avcc.reserveCapacity(frame.count + 4 * units.count)
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: unit)
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block, offsetIntoDestination: 0,
                                                       dataLength: avcc.count) == noErr else { return }
        var sample: CMSampleBuffer?
        var size = avcc.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status == noErr, let image {
                self.onFrame?(image)
            } else {
                self.fail()
            }
        }
        if status != noErr { fail() }
    }

    private func fail() {
        failures += 1
        broken = true
    }

    private func makeSession(sps: [UInt8], pps: [UInt8]) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        var description: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [s.baseAddress!, p.baseAddress!],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard let description else { return }
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false,
        ]
        let output: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                           decoderSpecification: specification as CFDictionary,
                                           imageBufferAttributes: output as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &created) == noErr else { return }
        session = created
        format = description
        parameterSets = (sps, pps)
        broken = false
    }

    /// Splits Annex B data into NAL units (without start codes).
    static func nalUnits(_ data: [UInt8]) -> [[UInt8]] {
        var starts: [Int] = []
        var i = 0
        while i + 3 < data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }
        return starts.enumerated().compactMap { n, start in
            let end = n + 1 < starts.count ? starts[n + 1] - 4 : data.count
            return end > start ? Array(data[start..<end]) : nil
        }
    }
}
