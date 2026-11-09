// Stand-ins for controls and readouts the views show but that aren't wired
// to the camera yet. Every value here is a placeholder: when one works for
// real, move it to Pipeline (or wherever it belongs), point the views at
// it, and delete it from here. Searching for "Planned." finds every view
// that uses one.

import SwiftUI

@MainActor
final class Planned: ObservableObject {
    static let shared = Planned()

    // MARK: Readouts

    /// The camera's battery level, 0-100, or nil when unknown.
    /// STUB: read it from the camera.
    @Published var battery: Int? = 62

    /// The app using the Mark One camera, for "In use by FaceTime".
    /// STUB: the camera extension would need to find out which app it is.
    @Published var activeApp: String? = "FaceTime"

    // MARK: Picture

    enum WhiteBalance: String, CaseIterable, Identifiable {
        case auto = "Auto", daylight = "Daylight", indoor = "Indoor"
        var id: Self { self }
    }

    enum PictureMode: String, CaseIterable, Identifiable {
        case natural = "Natural", vivid = "Vivid", muted = "Muted", portrait = "Portrait", monotone = "Monotone"
        var id: Self { self }
    }

    /// STUB: set the camera's white balance.
    @Published var whiteBalance = WhiteBalance.auto
    /// STUB: set the camera's picture mode.
    @Published var pictureMode = PictureMode.natural
    /// STUB: turn on the camera's face priority autofocus.
    @Published var faceFocus = true

    // MARK: Behaviour

    enum Grace: TimeInterval, CaseIterable, Identifiable {
        case short = 5, medium = 30, long = 120
        var id: Self { self }
        var label: String {
            switch self {
            case .short: "After 5 seconds"
            case .medium: "After 30 seconds"
            case .long: "After 2 minutes"
            }
        }
    }

    /// How long to keep recording after the last app stops using the camera.
    /// STUB: Pipeline.grace is fixed at 5 seconds.
    @Published var grace = Grace.short
    /// STUB: mirror the panel's preview.
    @Published var mirrorPreview = false
    /// STUB: show Mark One in the Dock as well as the menu bar.
    @Published var showInDock = false
    /// STUB: post a notification when the camera is switched off mid-session.
    @Published var notifyWhenOff = true
}

/// The camera's battery level, as a battery symbol and a percentage.
struct BatteryLevel: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(level)%").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera battery \(level) percent")
    }

    private var symbol: String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
