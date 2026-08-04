import AppKit

/// Where the panel hangs, and what shape it takes at rest.
///
/// On a MacBook with a camera housing it *is* the notch. Everywhere else — an
/// Air from before 2022, a Mac mini, an external display as the main screen — it
/// becomes a floating pill just below the menu bar. Same window, same level,
/// same behaviour; only the geometry and the corners differ.
///
/// Making this one type is what stops the app from exiting on half the Macs
/// that exist.
struct Placement {
    enum Style {
        /// Sits in the camera housing: flush with the screen edge, concave
        /// shoulders where it meets the menu bar.
        case notch
        /// Floats below the menu bar: rounded all round, since there is no
        /// hardware for it to blend into.
        case pill
    }

    let style: Style
    /// Size at rest, in points.
    let size: CGSize
    /// Rect at rest, in global (bottom-left origin) screen coordinates.
    let rect: CGRect
    let screen: NSScreen

    /// The pill's resting size. Wide enough to read a label, small enough to
    /// forget about.
    private static let pillSize = CGSize(width: 128, height: 26)

    // MARK: - Resolution

    static func current() -> Placement? {
        if !Settings.preferPill,
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let placement = notch(on: notched) {
            return placement
        }
        guard let screen = NSScreen.main else { return nil }
        return pill(on: screen)
    }

    private static func notch(on screen: NSScreen) -> Placement? {
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

        return Placement(
            style: .notch,
            size: CGSize(width: maxX - minX, height: height),
            rect: CGRect(x: minX, y: screen.frame.maxY - height,
                         width: maxX - minX, height: height),
            screen: screen)
    }

    private static func pill(on screen: NSScreen) -> Placement {
        // `visibleFrame` excludes the menu bar, so its top edge is exactly where
        // the pill can sit without covering menu items.
        let top = screen.visibleFrame.maxY
        let size = pillSize
        return Placement(
            style: .pill,
            size: size,
            rect: CGRect(x: screen.frame.midX - size.width / 2,
                         y: top - size.height,
                         width: size.width, height: size.height),
            screen: screen)
    }

    var describedForLog: String {
        let kind = style == .notch ? "notch" : "pill"
        return "\(kind) \(Int(size.width))×\(Int(size.height))pt at \(rect)"
    }
}
