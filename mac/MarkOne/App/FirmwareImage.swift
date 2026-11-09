// Builds Mark One's camera firmware on the Mac: download Olympus's stock
// E-M5 firmware 2.3 from Olympus's update server, check it, and apply
// Mark One's changes, which ship as byte edits (webcam-firmware.json, made
// by `scripts/build.py --edits`). Mark One never includes Olympus's code.

import CryptoKit
import Foundation

enum FirmwareImageError: LocalizedError {
    case server, download, notStock, badResult

    var errorDescription: String? {
        switch self {
        case .server: "Olympus's update server didn't answer. Check your internet connection and try again."
        case .download: "The download from Olympus didn't finish. Try again."
        case .notStock: "The file from Olympus isn't the firmware Mark One expects, so Mark One won't change it."
        case .badResult: "Mark One couldn't build its firmware correctly, so it stopped before writing anything."
        }
    }
}

struct FirmwareImage {
    /// The revision of Mark One's changes in this app, which the camera reports too.
    let revision: Int
    let data: Data

    /// The file name the camera's card updater looks for, in DCOLYMP.
    static let cardFileName = "E0972300.BIN"

    private struct Edits: Decodable {
        let stock_sha256: String
        let sha256: String
        let size: Int
        let revision: Int
        let edits: [[Edit]]

        enum Edit: Decodable {
            case offset(Int), bytes(String)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Int.self) { self = .offset(n) } else { self = .bytes(try c.decode(String.self)) }
            }
        }
    }

    private static let edits: Edits = {
        let url = Bundle.main.url(forResource: "webcam-firmware", withExtension: "json")!
        return try! JSONDecoder().decode(Edits.self, from: Data(contentsOf: url))
    }()

    /// The revision this app installs.
    static var bundledRevision: Int { edits.revision }

    /// Olympus's own firmware 2.3, unchanged, for putting the camera back
    /// to stock. Its revision is 0.
    static func olympus(progress: @escaping @Sendable (Double) -> Void) async throws -> FirmwareImage {
        FirmwareImage(revision: 0, data: try await stockFirmware(progress: progress))
    }

    /// Downloads stock firmware (or uses the copy from last time) and builds
    /// Mark One's firmware from it. `progress` gets 0 to 1 during the download.
    static func make(progress: @escaping @Sendable (Double) -> Void) async throws -> FirmwareImage {
        let stock = try await stockFirmware(progress: progress)
        var data = stock
        for edit in edits.edits {
            guard edit.count == 2, case .offset(let offset) = edit[0], case .bytes(let hex) = edit[1] else {
                throw FirmwareImageError.badResult
            }
            let bytes = Data(hex: hex)
            data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        guard data.count == edits.size, sha256(data) == edits.sha256 else { throw FirmwareImageError.badResult }
        return FirmwareImage(revision: edits.revision, data: data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the stock download is kept, so it's only fetched once.
    private static var cached: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("OLY_E_097_2300_0000_0000.BIN")
    }

    private static func stockFirmware(progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        if let data = try? Data(contentsOf: cached), sha256(data) == edits.stock_sha256 {
            progress(1)
            return data
        }
        let url = try await downloadURL()
        let data = try await download(url, progress: progress)
        guard sha256(data) == edits.stock_sha256 else { throw FirmwareImageError.notStock }
        try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cached)
        return data
    }

    /// Asks Olympus's update server, as OM Workspace does, for the E-M5's
    /// firmware. It answers with a signed link to the latest version, 2.3.
    private static func downloadURL() async throws -> URL {
        let time = { () -> String in
            let f = DateFormatter()
            f.dateFormat = "yyyyMMddHHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()
        let body = """
        <?xml version="1.0"?>
        <firmware_demand>
        <revision>0001</revision>
        <mac_address>00-00-00-00-00-00</mac_address>
        <time>\(time)</time>
        <language>ENU</language>
        <application>FWUT</application>
        <type>0000</type>
        <version>00005000</version>
        <os>WIN</os>
        <country_code>0001</country_code>
        <hardwares>
        <firmup_mode>0</firmup_mode>
        <hardware_info>
        <hard_code>OLYE097000000000</hard_code>
        <firmware_version>00001000</firmware_version>
        <serial_no>000000000</serial_no>
        <default_languages><code>ENU</code></default_languages>
        </hardware_info>
        </hardwares>
        </firmware_demand>
        """
        var request = URLRequest(url: URL(string: "https://fw01.om-digitalsolutions.net/ww_inform/fcache.do")!)
        request.httpMethod = "POST"
        request.setValue("Olympus", forHTTPHeaderField: "User-Agent")
        request.setValue("text/xml; Charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "<url>"), let end = text.range(of: "</url>", range: start.upperBound..<text.endIndex),
              let url = URL(string: String(text[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "&amp;", with: "&"))
        else { throw FirmwareImageError.server }
        return url
    }

    private static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let (bytes, response) = try? await URLSession.shared.bytes(from: url) else { throw FirmwareImageError.download }
        let total = max(Int(response.expectedContentLength), edits.size)
        var data = Data()
        data.reserveCapacity(total)
        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 16)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    data.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    progress(Double(data.count) / Double(total))
                }
            }
        } catch {
            throw FirmwareImageError.download
        }
        data.append(contentsOf: buffer)
        progress(1)
        return data
    }
}
