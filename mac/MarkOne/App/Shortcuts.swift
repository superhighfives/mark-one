// Global keyboard shortcuts, set in Settings > Camera.

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Focuses the camera, like the panel's Focus button. No default, so it
    /// can't clash with another app's shortcut until someone picks one.
    static let focus = Self("focus")
}

@MainActor
enum Shortcuts {
    static func start(_ pipeline: Pipeline) {
        KeyboardShortcuts.onKeyUp(for: .focus) { [weak pipeline] in
            guard let pipeline, pipeline.canFocus else { return }
            pipeline.focus()
        }
    }
}
