// Small pieces shared by the menu bar panel, the welcome window and Settings.

import ServiceManagement
import SwiftUI

/// Mark One's red: used only for the camera being live.
extension Color {
    static let live = Color(red: 0.90, green: 0.20, blue: 0.16)
}

/// A rounded panel for grouping content inside the menu bar panel and the
/// welcome window.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// The red badge over the preview while the camera is live.
struct LiveBadge: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .opacity(dim ? 0.35 : 1)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.live, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}

/// A numbered step in a list of instructions.
struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.background)
                .frame(width: 18, height: 18)
                .background(.primary, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A line drawing of the E-M5 from the front: silver top plate with the
/// viewfinder hump, leatherette body, lens, and the self-timer lamp, which
/// is lit red while the camera is live.
struct CameraSketch: View {
    var lit = false
    var faded = false

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 120, size.height / 80)
            context.translateBy(x: (size.width - 120 * scale) / 2, y: (size.height - 80 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let ink = GraphicsContext.Shading.color(.primary)
            let line = StrokeStyle(lineWidth: 1.6, lineJoin: .round)

            var hump = Path()
            hump.move(to: CGPoint(x: 44, y: 26))
            hump.addLine(to: CGPoint(x: 51, y: 11))
            hump.addLine(to: CGPoint(x: 69, y: 11))
            hump.addLine(to: CGPoint(x: 76, y: 26))
            let body = Path(roundedRect: CGRect(x: 8, y: 26, width: 104, height: 44), cornerRadius: 6)
            let dials = [CGRect(x: 15, y: 20, width: 15, height: 6), CGRect(x: 90, y: 20, width: 15, height: 6)]

            let leather = UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                .path(in: CGRect(x: 8, y: 38, width: 104, height: 32))
            if !faded {
                context.fill(hump, with: .color(Color(white: 0.88)))
                context.fill(body, with: .color(Color(white: 0.88)))
                context.fill(leather, with: .color(Color(white: 0.17)))
            }
            context.stroke(hump, with: ink, style: line)
            context.stroke(body, with: ink, style: line)
            for dial in dials {
                let shape = Path(roundedRect: dial, cornerRadius: 2)
                if !faded { context.fill(shape, with: .color(Color(white: 0.78))) }
                context.stroke(shape, with: ink, lineWidth: 1.2)
            }
            // The lens is a little taller than the body, so it covers the
            // body's top and bottom edges.
            let lens = Path(ellipseIn: CGRect(x: 35, y: 23, width: 50, height: 50))
            let glass = Path(ellipseIn: CGRect(x: 43, y: 31, width: 34, height: 34))
            if faded {
                var erase = context
                erase.blendMode = .clear
                erase.fill(lens, with: ink)
                context.stroke(lens, with: ink, style: line)
                context.stroke(glass, with: ink, lineWidth: 1.2)
            } else {
                context.fill(lens, with: .color(Color(white: 0.11)))
                context.fill(glass, with: .color(Color(red: 0.17, green: 0.21, blue: 0.31)))
                context.fill(Path(ellipseIn: CGRect(x: 50, y: 38, width: 8, height: 8)), with: .color(Color(red: 0.62, green: 0.70, blue: 0.85).opacity(0.8)))
            }
            let lamp = CGRect(x: 96.5, y: 29.5, width: 5, height: 5)
            if lit {
                context.fill(Path(ellipseIn: lamp.insetBy(dx: -4, dy: -4)), with: .color(Color.live.opacity(0.25)))
                context.fill(Path(ellipseIn: lamp), with: .color(.live))
            } else if !faded {
                context.fill(Path(ellipseIn: lamp), with: .color(Color(white: 0.55)))
            }
        }
        .opacity(faded ? 0.45 : 1)
        .accessibilityLabel(lit ? "E-M5 (Mark I) camera, live" : "E-M5 (Mark I) camera")
    }
}

/// A control with its label in a fixed-width column, so the controls in a
/// stack of rows line up and fill the rest of the width.
struct ControlRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 92, alignment: .leading)
                .accessibilityHidden(true)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
        // The same height for every row, so a slider's row isn't shorter
        // than a menu's and the labels sit evenly apart.
        .frame(minHeight: 26)
    }
}

/// A pop-up menu that fills its width. SwiftUI's menu pickers keep their own.
struct PopUp<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(label)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(of: selection) { button.selectItem(at: index) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUp
        init(_ parent: PopUp) { self.parent = parent }
        @objc func picked(_ sender: NSPopUpButton) {
            parent.selection = parent.options[sender.indexOfSelectedItem]
        }
    }
}

/// A segmented control whose segments share its full width.
struct Segments<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(label), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.picked(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if let index = options.firstIndex(of: selection) { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: Segments
        init(_ parent: Segments) { self.parent = parent }
        @objc func picked(_ sender: NSSegmentedControl) {
            parent.selection = parent.options[sender.selectedSegment]
        }
    }
}

/// Brightness, in thirds of a stop of exposure compensation.
struct BrightnessControl: View {
    @ObservedObject var pipeline: Pipeline
    var showsLabel = true

    var body: some View {
        if showsLabel {
            LabeledContent {
                slider
            } label: {
                Text("Brightness")
            }
            .accessibilityValue(label)
        } else {
            slider
                .accessibilityLabel("Brightness")
                .accessibilityValue(label)
        }
    }

    private var slider: some View {
        HStack {
            Slider(value: Binding(get: { Double(pipeline.brightness) },
                                  set: { pipeline.brightness = Int($0.rounded()) }),
                   in: -9...9, step: 1)
                .labelsHidden()
            Text(label)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var label: String {
        pipeline.brightness == 0 ? "±0.0 EV" : String(format: "%+.1f EV", Double(pipeline.brightness) / 3)
    }
}

/// Open at login, kept in step with what macOS reports.
struct OpenAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Open at login", isOn: $on)
            .onChange(of: on) { _, wanted in
                do {
                    try wanted ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                } catch {
                    on = SMAppService.mainApp.status == .enabled
                }
            }
    }
}

/// Dims the preview with a spinner while the picture freezes, and shows a
/// small spinner while the camera focuses, so the picture stays visible.
struct PreviewOverlay: View {
    let busy: String?
    let focusing: Bool

    var body: some View {
        ZStack {
            if let busy {
                Color.black.opacity(0.5)
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(busy).font(.callout).foregroundStyle(.white)
                }
                .transition(.opacity)
            } else if focusing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Focusing").font(.caption).foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: busy)
        .animation(.easeInOut(duration: 0.2), value: focusing)
        .allowsHitTesting(false)
    }
}

/// The camera's battery in the steps it actually reports. It sends a
/// percentage, but coarsely: 100 for most of a charge, then 50 once its
/// own battery icon flashes empty (see NOTES.md, "Objects and settings").
enum CameraBattery {
    case full, low, empty

    init(level: Int) {
        switch level {
        case 75...: self = .full
        case 26...: self = .low
        default: self = .empty
        }
    }

    var label: String {
        switch self {
        case .full: "Full"
        case .low: "Low"
        case .empty: "Empty"
        }
    }

    var symbol: String {
        switch self {
        case .full: "battery.100percent"
        case .low: "battery.25percent"
        case .empty: "battery.0percent"
        }
    }

    var color: Color? {
        switch self {
        case .full: nil
        case .low: .orange
        case .empty: .red
        }
    }
}

/// The camera's battery, as a battery symbol and a word.
struct BatteryLevel: View {
    let level: Int

    var body: some View {
        let battery = CameraBattery(level: level)
        HStack(spacing: 4) {
            Image(systemName: battery.symbol)
            Text(battery.label)
        }
        .font(.caption)
        .foregroundStyle(battery.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera battery \(battery.label.lowercased())")
    }
}

/// A copy of what the camera's screen shows while it installs firmware: a
/// "don't touch" and a "don't unplug" sign, with the update arrows above them
/// switching on and off every second. The camera cuts between the two
/// frames, so this does too.
struct CameraUpdateScreen: View {
    /// Draws one frame, for rendering a still.
    var arrows: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let blue = Color(red: 0.70, green: 0.86, blue: 0.96)
    private static let orange = Color(red: 0.98, green: 0.62, blue: 0.20)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let second = Int(timeline.date.timeIntervalSinceReferenceDate)
            screen(arrows: arrows ?? (reduceMotion || second.isMultiple(of: 2)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The camera's screen shows signs saying not to touch it or unplug it, and an update symbol.")
    }

    private func screen(arrows: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Self.blue)
                .opacity(arrows ? 1 : 0)
            HStack(spacing: 22) {
                forbidden {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 32))
                }
                forbidden {
                    VStack(spacing: 1) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 11, weight: .heavy))
                        HStack(spacing: 2) {
                            Image(systemName: "powerplug.fill")
                                .font(.system(size: 13))
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22))
                        }
                        .offset(x: 6)
                    }
                }
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// A sign inside an orange circle with a slash through it.
    private func forbidden(@ViewBuilder _ sign: () -> some View) -> some View {
        let size: CGFloat = 56
        let line: CGFloat = 5
        return ZStack {
            sign()
                .foregroundStyle(Self.blue)
                .frame(width: size, height: size)
                .clipShape(Circle())
            Rectangle()
                .fill(Self.orange)
                .frame(width: size - line, height: line)
                .rotationEffect(.degrees(40))
            Circle().strokeBorder(Self.orange, lineWidth: line)
        }
        .frame(width: size, height: size)
    }
}

/// The menu the camera shows when it's plugged in with USB Mode on Auto,
/// redrawn from photos of its screen (as on the website's help page), with
/// the choice to make highlighted. Olympus's firmware has no Webcam.
struct CameraUSBMenu: View {
    enum Choice: String { case mtp = "MTP", webcam = "Webcam" }
    let choose: Choice
    var width: CGFloat = 200

    private var items: [String] {
        choose == .webcam ? ["Storage", "MTP", "Webcam", "Print", "Exit"]
                          : ["Storage", "MTP", "Print", "Exit"]
    }

    var body: some View {
        // Sizes are fractions of the screen's width, as on the website.
        let w = width
        let height = w * 3 / 4
        ZStack(alignment: .top) {
            RadialGradient(stops: [.init(color: Color(red: 0.17, green: 0.37, blue: 0.85), location: 0),
                                   .init(color: Color(red: 0.09, green: 0.23, blue: 0.58), location: 0.35),
                                   .init(color: Color(red: 0.04, green: 0.09, blue: 0.22), location: 0.7),
                                   .init(color: .black, location: 1)],
                           center: UnitPoint(x: 0.5, y: 0.55), startRadius: 0, endRadius: w * 0.55)
            VStack(spacing: w * 0.016) {
                Text("USB").font(.system(size: w * 0.052, weight: .bold))
                LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: max(1, w * 0.0035))
            }
            .padding(.horizontal, w * 0.12)
            .padding(.top, height * 0.04)
            VStack(spacing: 0) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.system(size: w * 0.054, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, w * 0.0035)
                        .background {
                            if item == choose.rawValue {
                                RoundedRectangle(cornerRadius: w * 0.004)
                                    .fill(LinearGradient(colors: [Color(red: 0.56, green: 0.64, blue: 0.80),
                                                                  Color(red: 0.29, green: 0.40, blue: 0.62)],
                                                         startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: w * 0.004)
                                        .strokeBorder(Color(red: 0.90, green: 0.93, blue: 0.98), lineWidth: max(1, w * 0.0045)))
                                    .shadow(color: Color(red: 0.78, green: 0.86, blue: 1).opacity(0.5), radius: w * 0.012)
                            }
                        }
                }
            }
            .padding(.horizontal, w * 0.12)
            .padding(.top, height * 0.28 - w * 0.02)
            VStack {
                Spacer()
                HStack(spacing: w * 0.008) {
                    Spacer()
                    Text("Set")
                    Text("OK")
                        .font(.system(size: w * 0.034, weight: .medium))
                        .foregroundStyle(Color(red: 0.24, green: 0.44, blue: 0.71))
                        .padding(.horizontal, w * 0.008)
                        .background(.white, in: RoundedRectangle(cornerRadius: w * 0.004))
                }
                .font(.system(size: w * 0.046, weight: .bold))
                .padding(.horizontal, w * 0.03)
                .frame(height: height * 0.1)
                .background(LinearGradient(stops: [.init(color: Color(red: 0.65, green: 0.78, blue: 0.93), location: 0),
                                                   .init(color: Color(red: 0.42, green: 0.61, blue: 0.85), location: 0.45),
                                                   .init(color: Color(red: 0.25, green: 0.45, blue: 0.72), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .white.opacity(0.35), radius: w * 0.006)
        .frame(width: w, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .padding(w * 0.03)
        .background(Color(white: 0.043), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The camera's USB menu: \(items.joined(separator: ", ")), with \(choose.rawValue) selected")
    }
}

/// The two things to click in System Settings to allow the camera (macOS
/// 27, General › Login Items & Extensions), redrawn side by side with
/// their step numbers: Mark One's row in the extensions list, with its ⓘ
/// ringed, then the Media Extension switch in the sheet it opens, on and
/// ringed. macOS calls the camera a Media Extension.
struct ExtensionApprovalSteps: View {
    var body: some View {
        HStack(spacing: 8) {
            panel(2) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mark One").font(.system(size: 12))
                    Text("Media Extension").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .overlay(Circle().strokeBorder(.orange, lineWidth: 2))
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            panel(3) {
                Image(systemName: "video.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color(white: 0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Media Extension").font(.system(size: 12)).fixedSize()
                Spacer(minLength: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 30, height: 17)
                    .overlay(alignment: .trailing) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(.trailing, 1.5)
                    }
                    .padding(3)
                    .overlay(Capsule().strokeBorder(.orange, lineWidth: 2))
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, the ⓘ button beside Mark One, then the Media Extension switch, turned on")
    }

    /// One row as System Settings draws it, tagged with its step.
    private func panel(_ step: Int, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .overlay(alignment: .topLeading) {
                Text("\(step)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: 16, height: 16)
                    .background(.white, in: Circle())
                    .offset(x: -6, y: -6)
            }
    }
}
