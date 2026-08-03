import AppKit

/// Physical geometry of the built-in camera housing ("the notch") on a given screen.
///
/// Nothing here is hardcoded: 14" and 16" MacBook Pros differ, and external
/// displays have no notch at all. Always resolve this at runtime and re-resolve
/// when the screen configuration changes.
struct NotchGeometry {
    /// Notch size in points, in the screen's own coordinate space.
    let size: CGSize
    /// Rect the notch occupies, in global (bottom-left origin) screen coordinates.
    let rect: CGRect
    /// The screen this geometry was measured on.
    let screen: NSScreen

    init?(screen: NSScreen) {
        guard
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        else { return nil }

        let height = screen.safeAreaInsets.top
        guard height > 0 else { return nil }

        // auxiliaryTop*Area are the menu bar strips flanking the housing, so the
        // gap between them is the notch itself. Deriving it this way avoids any
        // assumption about where the screen's origin sits.
        let minX = left.maxX
        let maxX = right.minX
        guard maxX > minX else { return nil }

        self.size = CGSize(width: maxX - minX, height: height)
        self.rect = CGRect(x: minX, y: screen.frame.maxY - height,
                           width: maxX - minX, height: height)
        self.screen = screen
    }

    /// The screen we should live on: the built-in display with a notch, if any.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static func current() -> NotchGeometry? {
        guard let screen = preferredScreen() else { return nil }
        return NotchGeometry(screen: screen)
    }
}
