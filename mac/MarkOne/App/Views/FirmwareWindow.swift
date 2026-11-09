// Opening the Camera Firmware window, and naming a camera's firmware.

import SwiftUI

extension OpenWindowAction {
    /// Opens the Camera Firmware window in front of everything else.
    func firmware() {
        self(id: "firmware")
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension CameraFirmware {
    /// Whether Mark One has newer firmware for this camera than it has now.
    var updateAvailable: Bool {
        if case .markOne(let revision) = self { return revision < FirmwareImage.bundledRevision }
        return false
    }

    var label: String {
        switch self {
        case .stock: "Olympus’s own"
        case .markOne(0): "Mark One"
        case .markOne(let revision): "Mark One, revision \(revision)"
        }
    }
}
