// Follows the camera's H.264 stream while it records a movie. A port of
// scripts/stream.py; its docstrings and NOTES.md explain the details.
//
// Frames sit back to back in a ring from 0xa52b1c00, wrapping to its start.
// The recorder's table of frame descriptors lags behind the encoder, so it
// is only a hint: each frame is checked by content. Its picture timing and
// frame number must follow the previous frame's, it ends where the next
// such header begins, and a frame identical to one already sent from the
// same address is left over from an earlier lap of the ring.

import Foundation

struct FrameHeader {
    var cpb: Int?             // SEI picture timing, +2 a frame, 2..60
    var frameNum: Int?        // slice frame_num, resets at each IDR
    var idr = false
    let ok: Bool

    static let aud = Data([0, 0, 0, 1, 9])

    init(_ data: Data) {
        let bytes = [UInt8](data.prefix(1024))
        ok = bytes.starts(with: FrameHeader.aud)
        guard ok else { return }
        let sei: [UInt8] = [0, 0, 0, 1, 6, 1, 9]
        if let at = bytes.firstRange(of: sei)?.lowerBound, at + 16 <= bytes.count {
            let raw = FrameHeader.unescape(Array(bytes[(at + 7)..<(at + 16)]))
            cpb = raw.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        }
        var i = 5
        while i + 16 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1, [1, 5].contains(bytes[i + 4] & 0x1F) {
                idr = bytes[i + 4] & 0x1F == 5
                var bits = BitReader(FrameHeader.unescape(Array(bytes[(i + 5)..<(i + 16)])))
                for _ in 0..<3 { _ = bits.ue() }         // first_mb, slice_type, pps_id
                frameNum = bits.bits(4)                  // log2_max_frame_num = 4
                break
            }
            i += 1
        }
    }

    /// Whether this frame comes right after `before` (not stale data).
    func follows(_ before: FrameHeader?) -> Bool {
        guard ok, let before, let previous = before.cpb, let previousNum = before.frameNum,
              let cpb, let frameNum else { return false }
        guard cpb == (previous >= 60 ? 2 : previous + 2) else { return false }
        return frameNum == (idr ? 0 : (previousNum + 1) % 16)
    }

    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for b in bytes {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}

struct BitReader {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bit() -> Int {
        guard position / 8 < bytes.count else { return 0 }
        defer { position += 1 }
        return Int(bytes[position / 8] >> (7 - position % 8)) & 1
    }

    mutating func bits(_ n: Int) -> Int { (0..<n).reduce(0) { acc, _ in acc << 1 | bit() } }

    mutating func ue() -> Int {
        var zeros = 0
        while bit() == 0 && zeros < 32 { zeros += 1 }
        return (1 << zeros) - 1 + bits(zeros)
    }
}

/// Reads finished frames from the camera's movie recorder.
final class Streamer {
    static let table = UInt32(0xA07E_5180), entries = 60, entrySize = 0xF4
    static let inProgress = 0xBF440                   // placeholder size while a frame is encoded
    static let ringLow = UInt32(0xA52B_1C00), ringHigh = UInt32(0xA561_1380)
    static let scan = 0x60000                          // bytes to search for the end of a frame
    static let head = 1024                             // bytes of a frame that identify it
    static let wrapRoom = UInt32(0x10_0000)            // the encoder wraps with 0x95000-0xc4000 bytes left

    private let camera: Camera
    private var header: FrameHeader?
    private var end = UInt32(0)
    private var sent: [UInt32: Data] = [:]
    private var sentOrder: [UInt32] = []
    private var lastFrame = Date()

    init(camera: Camera) { self.camera = camera }

    /// Frames that are ready, oldest first; empty if none are yet.
    func poll() throws -> [Data] {
        let hints = try sizes()
        var starts = header == nil ? Array(hints.order.suffix(20).reversed()) : [end, Streamer.ringLow]
        var frames: [Data] = []
        while let (address, data, frameHeader) = try take(starts: starts, before: header, hints: hints.sizes) {
            header = frameHeader
            remember(address, data.prefix(Streamer.head))
            end = address + UInt32(data.count)
            starts = [end, Streamer.ringLow]
            frames.append(data)
        }
        if !frames.isEmpty {
            lastFrame = Date()
        } else if header != nil, Date().timeIntervalSince(lastFrame) > 1 {
            header = nil                               // a new recording, or we lost track
        }
        return frames
    }

    /// Whether the recorder is producing frames.
    var streaming: Bool { header != nil && Date().timeIntervalSince(lastFrame) < 1 }

    private func remember(_ address: UInt32, _ head: Data) {
        sent[address] = head
        sentOrder.append(address)
        if sentOrder.count > 200 { sent[sentOrder.removeFirst()] = nil }
    }

    /// Finished frames the table lists, as sizes by address and addresses oldest first.
    private func sizes() throws -> (sizes: [UInt32: Int], order: [UInt32]) {
        let start = Streamer.table - 52
        let raw = try camera.peek(start, Streamer.entries * Streamer.entrySize + 52)
        var found: [(number: UInt32, address: UInt32, size: Int)] = []
        for k in 0..<Streamer.entries {
            let base = 52 + k * Streamer.entrySize
            let number = raw.le(UInt32.self, at: base + 4), address = raw.le(UInt32.self, at: base + 8)
            let size = Int(raw.le(UInt32.self, at: base - 48))
            if number != 0, (Streamer.ringLow..<Streamer.ringHigh).contains(address), size > 0, size < Streamer.inProgress {
                found.append((number, address, size))
            }
        }
        found.sort { $0.number < $1.number }
        return (Dictionary(found.map { ($0.address, $0.size) }, uniquingKeysWith: { $1 }), found.map(\.address))
    }

    /// Reads `size` bytes at a possibly odd address (USB transfers need even ones).
    private func read(_ address: UInt32, _ size: Int) throws -> Data {
        let start = address & ~1
        let length = (Int(address - start) + size + 1) & ~1
        let data = try camera.peek(start, length)
        let offset = Int(address - start)
        return data.subdata(in: offset..<min(data.count, offset + size))
    }

    private func newHeader(_ address: UInt32, _ head: Data) -> FrameHeader? {
        sent[address] == head.prefix(Streamer.head) ? nil : FrameHeader(head)
    }

    /// The next frame, checked by content. See take() in scripts/stream.py.
    private func take(starts: [UInt32], before: FrameHeader?, hints: [UInt32: Int]) throws -> (UInt32, Data, FrameHeader)? {
        var chosen: (UInt32, FrameHeader)?
        for start in starts {
            if let h = newHeader(start, try read(start, Streamer.head)), before.map({ h.follows($0) }) ?? h.idr {
                chosen = (start, h)
                break
            }
        }
        guard let (start, header) = chosen else { return nil }
        if let hint = hints[start] {
            let data = try read(start, hint + Streamer.head)
            var candidates: [(UInt32, Data?)] = [(start + UInt32(hint), data.subdata(in: hint..<data.count))]
            if Streamer.ringHigh - (start + UInt32(hint)) < Streamer.wrapRoom { candidates.append((Streamer.ringLow, nil)) }
            for (next, head) in candidates {
                let bytes = try head ?? read(next, Streamer.head)
                if let after = newHeader(next, bytes), after.follows(header) {
                    return (start, data.prefix(hint), header)
                }
            }
        }
        // Without a size, the frame ends at the next delimiter, which can't
        // appear inside a frame. If the frame there doesn't follow this one,
        // the encoder hasn't written it yet and what's there is left over
        // from an earlier lap; searching further would find old frames.
        let data = try read(start, min(Streamer.scan, Int(Streamer.ringHigh - start)))
        guard let range = data.range(of: FrameHeader.aud, in: (data.startIndex + 5)..<data.endIndex) else { return nil }
        let offset = range.lowerBound - data.startIndex
        let next = start + UInt32(offset)
        if let after = newHeader(next, data.subdata(in: offset..<min(data.count, offset + Streamer.head))), after.follows(header) {
            return (start, data.prefix(offset), header)
        }
        return nil
    }
}
