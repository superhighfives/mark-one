// The menu bar icon: the app icon's dial as a ring with its index line,
// and the red LED beside it while the camera is recording. While the
// camera focuses, the index line turns around the ring.

import AppKit

enum MenuBarIcon {
    private static let live = image(live: true)
    private static let idle = image(live: false)

    static func image(recording: Bool) -> NSImage { recording ? live : idle }

    /// The icon with its index line `turn` of the way round (0 to 1,
    /// clockwise from the top), or hidden when nil, for focusing.
    static func image(recording: Bool, turn: Double?) -> NSImage { image(live: recording, turn: turn) }

    /// Not a template image, so the LED can be red. The dial is drawn in
    /// the menu bar's own label colour each time it's drawn, so it still
    /// follows light and dark menu bars.
    private static func image(live: Bool, turn: Double? = 0) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            let ink = NSColor.labelColor.withAlphaComponent(live ? 1 : 0.55)
            ink.setStroke()
            let center = NSPoint(x: 9, y: 10)
            let radius: CGFloat = 6.5
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 1.8
            ring.stroke()
            if let turn {
                // Flipped, so y grows downwards: angle 0 points up.
                let angle = turn * 2 * .pi
                let point = { (distance: CGFloat) in
                    NSPoint(x: center.x + distance * sin(angle), y: center.y - distance * cos(angle))
                }
                let index = NSBezierPath()
                index.move(to: point(radius - 0.5))
                index.line(to: point(radius - 4.2))
                index.lineWidth = 1.8
                index.lineCapStyle = .round
                index.stroke()
            }
            if live {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14.2, y: 1.2, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = live ? "Mark One, recording" : "Mark One"
        return image
    }
}
