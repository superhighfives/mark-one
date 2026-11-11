// Installs Mark One's firmware: onto an SD card for a camera that still has
// Olympus's firmware, or straight over USB for one that already has Mark
// One's, using the camera's own update commands (see NOTES.md, "Installing
// firmware over USB").

import AppKit
import Foundation

/// Which firmware a connected camera has.
enum CameraFirmware: Equatable {
    /// Olympus's own. Mark One's firmware goes on from the SD card first.
    case stock
    /// Mark One's, at this revision. 0 is a build from before revisions.
    case markOne(Int)
}

extension Firmware {
    static let revisionMarker = UInt32(0x7EAB_0414)

    /// Reads which firmware the camera has, from the commands it lists.
    /// Don't probe with a command stock firmware lacks: it doesn't answer
    /// "not supported", it stalls the USB pipe until the camera restarts.
    static func identify(_ camera: Camera) throws -> CameraFirmware {
        guard try camera.operations().contains(0x9484) else { return .stock }
        let marker = try camera.peek(revisionMarker, 8)
        guard marker.prefix(4) == Data("MARK".utf8) else { return .markOne(0) }
        return .markOne(Int(marker.le(UInt32.self, at: 4)))
    }

    /// Makes the camera report another firmware version until it's switched
    /// off, in the two places the firmware keeps it: the main block's head
    /// (shown in the menus) and the `mov 0x2300,d2` that GetVersions builds
    /// its answer from, which is what Olympus's updater reads.
    static func reportVersion(_ camera: Camera, major: Int, minor: Int) throws {
        let digits = UInt8(major << 4 | minor)
        try camera.poke(0x7E42_1010, Data([0x00, digits]))
        try camera.poke(0x7F0D_D972, Data([digits, 0xF2]))
    }

    /// How the camera connected: 2 for MTP, 7 for Webcam (the webcam patch's
    /// own type; see NOTES.md, "Webcam USB choice").
    static let connectionTypeAddress = UInt32(0x605F_0D14)
    static let webcamConnection = UInt32(7)

    static func connectionType(_ camera: Camera) throws -> UInt32 {
        try camera.peek(connectionTypeAddress, 4).le(UInt32.self, at: 0)
    }

    /// Whether this firmware build lets MTP use the update commands.
    static func canUpdateOverUSB(_ firmware: CameraFirmware) -> Bool {
        if case .markOne(let revision) = firmware { return revision >= 1 }
        return false
    }
}

enum InstallError: LocalizedError {
    case notReady, refused(String), rejected, cardWrite(Error)

    var errorDescription: String? {
        switch self {
        case .notReady: "The camera isn't ready to update. Turn it off and on, then try again."
        case .refused(let step): "The camera stopped the update while \(step). Nothing was installed."
        case .rejected: "The camera checked the firmware and rejected it. Nothing was installed."
        case .cardWrite(let error): "Mark One couldn't write to the card: \(error.localizedDescription)"
        }
    }
}

enum FirmwareInstall {
    /// Sends the firmware over USB the way OM Workspace does, then tells the
    /// camera to install it. The camera checks the file before it changes
    /// anything; once it starts installing, it must not lose power.
    /// `progress` gets a description and 0 to 1.
    /// Returns whether the camera restarts by itself once it's done (see
    /// `Firmware.armRestart`); otherwise it waits to be switched off and on.
    @discardableResult
    static func overUSB(_ camera: Camera, _ image: FirmwareImage,
                        progress: (String, Double) -> Void) throws -> Bool {
        let firm = image.data
        let mode = try camera.send(0x911C, [], name: "the update check").0
        guard mode.first == 1 else { throw InstallError.notReady }

        var info = Data()
        info.append(le: UInt32(0x8000_0001))          // storage
        info.append(le: UInt16(0xB001))               // format: firmware
        info.append(le: UInt16(0))
        info.append(le: UInt32(firm.count))
        info.append(Data(count: 48))
        do { try camera.send(0x9125, [0x8000_0001], data: info, name: "the firmware details") }
        catch CameraError.command { throw InstallError.refused("starting") }

        let piece = 0xF800
        var offset = 0
        while offset < firm.count {
            let chunk = firm.subdata(in: offset..<min(offset + piece, firm.count))
            do { try camera.send(0x9119, [UInt32(offset), UInt32(chunk.count)], data: chunk, name: "the firmware") }
            catch CameraError.command { throw InstallError.refused("receiving the firmware") }
            offset += chunk.count
            progress("Sending the firmware to the camera…", 0.2 * Double(offset) / Double(firm.count))
        }

        do { try camera.send(0x9121, [], name: "the firmware check") }
        catch CameraError.command { throw InstallError.rejected }
        let started = Date()
        while true {
            let status = try camera.send(0x9122, [], name: "the update status").0
            if status.first == 2 { break }
            guard status.first == 1 else { throw InstallError.rejected }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 180 { throw InstallError.rejected }
            progress("The camera is checking the firmware…", 0.2 + 0.3 * min(1, elapsed / 30))
            Thread.sleep(forTimeInterval: 1)
        }
        let restarts = (try? Firmware.armRestart(camera)) ?? false
        try camera.send(0x9123, [], name: "the update")
        return restarts
    }

    /// Removable volumes that look like a camera's SD card: a FAT or exFAT
    /// volume, preferring ones with a DCIM folder.
    static func cards() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let cards = volumes.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            let external = v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false
            let format = v.volumeLocalizedFormatDescription ?? ""
            return external && url.path != "/" && (format.contains("FAT") || format.contains("MS-DOS"))
        }
        return cards.sorted { a, _ in FileManager.default.fileExists(atPath: a.appendingPathComponent("DCIM").path) }
    }

    /// Writes the firmware where the camera's card updater looks for it,
    /// removing any other E-M5 firmware there, then ejects the card.
    static func writeToCard(_ volume: URL, _ image: FirmwareImage) throws {
        let folder = volume.appendingPathComponent("DCOLYMP")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.uppercased().hasPrefix("E097") && name.uppercased().hasSuffix(".BIN") {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            let file = folder.appendingPathComponent(FirmwareImage.cardFileName)
            try image.data.write(to: file)
            // Read it back, so a bad card shows up here, not in the camera.
            guard try Data(contentsOf: file, options: .uncached) == image.data else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            throw InstallError.cardWrite(error)
        }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }
}
