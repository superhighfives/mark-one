// Captures the website's screenshots: for each shot in screenshots/shots.json
// it says what to set up, counts down, then grabs that shot's window (found
// by app and title, no clicking) into screenshots/raw/<id>.png, without its
// shadow. Then run scripts/frame-screenshots.swift to frame them.
//
//   swift scripts/capture-screenshots.swift              every shot
//   swift scripts/capture-screenshots.swift 01-panel     only these shots
//   swift scripts/capture-screenshots.swift --delay 10   a longer countdown
//
// Run it from any folder. From a terminal it waits for Return before each
// countdown; otherwise it only counts down. The terminal needs Screen
// Recording permission (System Settings > Privacy & Security).

import AppKit

struct Target: Decodable {
    let app: String
    let title: String?
    let panel: Bool?
}

struct Shot: Decodable {
    let id: String
    let caption: String
    let capture: String
    let window: Target
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("screenshots")
let raw = folder.appendingPathComponent("raw")
let shots = try JSONDecoder().decode([Shot].self, from: Data(contentsOf: folder.appendingPathComponent("shots.json")))

var delay = 5
var only: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    if arg == "--delay", let value = args.popFirst().flatMap(Int.init) { delay = value } else { only.append(arg) }
}
let unknown = only.filter { id in !shots.contains { $0.id == id } }
guard unknown.isEmpty else {
    print("No shot called \(unknown.joined(separator: ", ")). Shots: \(shots.map(\.id).joined(separator: ", "))")
    exit(1)
}
let interactive = isatty(STDIN_FILENO) == 1

func play(_ sound: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    task.arguments = ["/System/Library/Sounds/\(sound).aiff"]
    try? task.run()
}

/// The window to capture: a menu bar panel is the app's biggest window above
/// the normal level (its menu bar icon is a small one); otherwise the app's
/// frontmost normal window, with the given title if there is one.
func findWindow(_ target: Target) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == target.app }
    func area(_ window: [String: Any]) -> CGFloat {
        guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return 0 }
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    func layer(_ window: [String: Any]) -> Int { window[kCGWindowLayer as String] as? Int ?? 0 }
    let match: [String: Any]?
    if target.panel == true {
        match = windows.filter { layer($0) > 0 && area($0) > 100 * 100 }.max { area($0) < area($1) }
    } else {
        match = windows.first {
            layer($0) == 0 && area($0) > 100 * 100
                && (target.title == nil || ($0[kCGWindowName as String] as? String) == target.title)
        }
    }
    return (match?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
}

try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
var missed: [String] = []

for shot in shots where only.isEmpty || only.contains(shot.id) {
    print("\n\(shot.id): \(shot.caption)")
    print("  Set up: \(shot.capture)")
    if interactive {
        print("  Press Return to start the countdown, or type s and Return to skip.", terminator: " ")
        if readLine()?.lowercased() == "s" { continue }
    }
    for second in stride(from: delay, through: 1, by: -1) {
        print("  \(second)…")
        play("Tink")
        sleep(1)
    }
    guard let id = findWindow(shot.window) else {
        let name = shot.window.title.map { "\"\($0)\" in \(shot.window.app)" }
            ?? (shot.window.panel == true ? "\(shot.window.app)'s menu bar panel" : "a \(shot.window.app) window")
        print("  Couldn't find \(name) on screen. Skipped.")
        missed.append(shot.id)
        continue
    }
    let file = raw.appendingPathComponent("\(shot.id).png")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l\(id)", file.path]
    try capture.run()
    capture.waitUntilExit()
    if capture.terminationStatus == 0 {
        play("Glass")
        print("  Saved screenshots/raw/\(shot.id).png")
    } else {
        print("  screencapture failed.")
        missed.append(shot.id)
    }
}

print(missed.isEmpty
    ? "\nDone. Frame them with: swift scripts/frame-screenshots.swift"
    : "\nMissed: \(missed.joined(separator: " ")). Try again with: swift scripts/capture-screenshots.swift \(missed.joined(separator: " "))")
