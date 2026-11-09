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
            let lens = Path(ellipseIn: CGRect(x: 42, y: 30, width: 36, height: 36))
            let glass = Path(ellipseIn: CGRect(x: 48, y: 36, width: 24, height: 24))
            if faded {
                context.stroke(lens, with: ink, style: line)
                context.stroke(glass, with: ink, lineWidth: 1.2)
            } else {
                context.fill(lens, with: .color(Color(white: 0.11)))
                context.fill(glass, with: .color(Color(red: 0.17, green: 0.21, blue: 0.31)))
                context.fill(Path(ellipseIn: CGRect(x: 53, y: 41, width: 6, height: 6)), with: .color(Color(red: 0.62, green: 0.70, blue: 0.85).opacity(0.8)))
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
        .accessibilityLabel(lit ? "E-M5 camera, live" : "E-M5 camera")
    }
}

/// Brightness, in thirds of a stop of exposure compensation.
struct BrightnessControl: View {
    @ObservedObject var pipeline: Pipeline
    var showsLabel = true

    var body: some View {
        LabeledContent {
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
        } label: {
            Text("Brightness")
        }
        .accessibilityValue(label)
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
