// Frames raw window captures into screenshots for the website: each capture
// from screenshots/raw/<id>.png goes on a 2880x1800 background, with its
// caption and detail from screenshots/shots.json, and is written to
// screenshots/framed/<id>.png. Shots without a capture yet are skipped.
//
//   swift scripts/frame-screenshots.swift
//
// Capture the windows first, on a Retina display:
//   swift scripts/capture-screenshots.swift

import AppKit

struct Shot: Decodable {
    let id: String
    let caption: String
    let detail: String
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("screenshots")
let shots = try JSONDecoder().decode([Shot].self, from: Data(contentsOf: folder.appendingPathComponent("shots.json")))
let output = folder.appendingPathComponent("framed")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let size = NSSize(width: 2880, height: 1800)
// The website's dark ground, with its two soft lights.
let ground = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x13 / 255, alpha: 1)
let blue = NSColor(red: 0x5b / 255, green: 0x6f / 255, blue: 0x86 / 255, alpha: 0.55)
let brown = NSColor(red: 0x7a / 255, green: 0x5a / 255, blue: 0x4c / 255, alpha: 0.5)
let ink = NSColor(red: 0xf2 / 255, green: 0xf2 / 255, blue: 0xef / 255, alpha: 1)
let quiet = NSColor(red: 0xb5 / 255, green: 0xb5 / 255, blue: 0xb1 / 255, alpha: 1)

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

for shot in shots {
    let raw = folder.appendingPathComponent("raw/\(shot.id).png")
    guard let capture = NSImage(contentsOf: raw),
          let captureRep = capture.representations.first else {
        print("skipped \(shot.id): no capture at raw/\(shot.id).png")
        continue
    }
    // Draw at the capture's pixel size, so a Retina capture stays sharp.
    let pixels = NSSize(width: captureRep.pixelsWide, height: captureRep.pixelsHigh)

    let image = NSImage(size: size, flipped: false) { rect in
        ground.setFill()
        rect.fill()
        for (color, center) in [(blue, NSPoint(x: 0.15, y: 0.9)), (brown, NSPoint(x: 0.9, y: 0.1))] {
            let gradient = NSGradient(starting: color, ending: color.withAlphaComponent(0))!
            gradient.draw(fromCenter: NSPoint(x: rect.width * center.x, y: rect.height * center.y), radius: 0,
                          toCenter: NSPoint(x: rect.width * center.x, y: rect.height * center.y), radius: rect.width * 0.55,
                          options: [])
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let caption = NSAttributedString(string: shot.caption, attributes: [
            .font: font(104, .heavy), .foregroundColor: ink, .paragraphStyle: paragraph, .kern: -2,
        ])
        let detail = NSAttributedString(string: shot.detail, attributes: [
            .font: font(46, .regular), .foregroundColor: quiet, .paragraphStyle: paragraph,
        ])
        caption.draw(in: NSRect(x: 160, y: rect.height - 300, width: rect.width - 320, height: 150))
        detail.draw(in: NSRect(x: 260, y: rect.height - 390, width: rect.width - 520, height: 80))

        // Fit the capture under the text, never larger than it was taken.
        let room = NSRect(x: 160, y: 80, width: rect.width - 320, height: rect.height - 520)
        let scale = min(1, room.width / pixels.width, room.height / pixels.height)
        let drawn = NSSize(width: pixels.width * scale, height: pixels.height * scale)
        capture.draw(in: NSRect(x: room.midX - drawn.width / 2, y: room.midY - drawn.height / 2,
                                width: drawn.width, height: drawn.height))
        return true
    }

    // Render at exactly 2880x1800 pixels, whatever the screen's scale.
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent("\(shot.id).png"))
    print("framed \(shot.id)")
}
