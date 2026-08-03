import SwiftUI

enum NotchState: Equatable {
    /// Invisible: we render exactly the physical notch so the overlay is undetectable.
    case closed
    /// Cursor is over the notch — a small tease, no content yet.
    case hover
    /// Clicked open — the full panel.
    case open
}

@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var state: NotchState = .closed

    /// Measured once at launch; the window is sized from this.
    let geometry: NotchGeometry

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Transitions

    /// Opening is always instantaneous — no hold, no delay. The haptic tick is
    /// what makes it read as a physical button rather than a laggy click.
    func open() {
        guard state != .open else { return }
        state = .open
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
    }

    func toggle() {
        state == .open ? close() : open()
    }

    /// Hover only tickles the shape; it never opens on its own.
    func setHovering(_ hovering: Bool) {
        guard state != .open else { return }
        state = hovering ? .hover : .closed
    }

    // MARK: - Layout

    /// Padding around the shape inside the window, leaving room for the
    /// inverted top corners to bleed outward and for the shadow.
    static let margin: CGFloat = 24

    var openSize: CGSize { CGSize(width: 580, height: 440) }

    /// Size of the shape for the current state.
    var currentSize: CGSize {
        switch state {
        case .closed:
            return geometry.size
        case .hover:
            // Just enough growth to read as "alive" without covering menu bar items.
            return CGSize(width: geometry.size.width + 24,
                          height: geometry.size.height + 6)
        case .open:
            return openSize
        }
    }

    /// Window size must fit the largest state; the rest is transparent and
    /// click-through (see `NotchContainerView.hitTest`).
    var windowSize: CGSize {
        CGSize(width: max(openSize.width, geometry.size.width) + Self.margin * 2,
               height: openSize.height + Self.margin)
    }

    /// Where the window sits in global screen coordinates: horizontally centred
    /// on the real notch, flush against the top of the screen.
    var windowOrigin: CGPoint {
        let size = windowSize
        return CGPoint(x: geometry.rect.midX - size.width / 2,
                       y: geometry.screen.frame.maxY - size.height)
    }

    /// Interactive area in window coordinates (bottom-left origin), i.e. the
    /// only region that should swallow mouse events.
    var activeRect: CGRect {
        let size = currentSize
        let window = windowSize
        return CGRect(x: (window.width - size.width) / 2,
                      y: window.height - size.height,
                      width: size.width,
                      height: size.height)
    }
}
