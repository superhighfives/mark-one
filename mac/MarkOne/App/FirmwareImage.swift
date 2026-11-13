// Builds Mark One's camera firmware on the Mac: take Olympus's stock E-M5
// firmware 2.3, which the user downloads and gives Mark One, check it, and
// apply Mark One's changes, which ship as byte edits (webcam-firmware.json,
// made by `scripts/build.py --edits`). Mark One never includes or
// downloads Olympus's code.

import CryptoKit
import Foundation

enum FirmwareImageError: LocalizedError {
    case noStock, notStock, badResult

    var errorDescription: String? {
        switch self {
        case .noStock: "Mark One needs Olympus's firmware 2.3 first."
        case .notStock: "That file isn't Olympus's E-M5 firmware 2.3 (\(FirmwareImage.stockFileName)), so Mark One won't use it."
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
    static func olympus() throws -> FirmwareImage {
        FirmwareImage(revision: 0, data: try stockFirmware())
    }

    /// Builds Mark One's firmware from the stock file the user gave Mark One.
    static func make() throws -> FirmwareImage {
        var data = try stockFirmware()
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

    /// Where Mark One keeps its copy of the stock file, so it's only asked for once.
    private static var cached: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent(stockFileName)
    }

    /// Olympus's name for E-M5 firmware 2.3.
    static let stockFileName = "OLY_E_097_2300_0000_0000.BIN"

    /// An unofficial page that gets the file from Olympus's servers for the
    /// user, since Olympus only hands it to its own updater.
    static let downloadPage = URL(string: "https://ofu.infinityfreeapp.com/")!

    /// Checks a file the user chose and keeps a copy of it.
    static func useStock(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), sha256(data) == edits.stock_sha256 else {
            throw FirmwareImageError.notStock
        }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cached)
    }

    private static func stockFirmware() throws -> Data {
        guard let data = try? Data(contentsOf: cached), sha256(data) == edits.stock_sha256 else {
            throw FirmwareImageError.noStock
        }
        return data
    }
}
