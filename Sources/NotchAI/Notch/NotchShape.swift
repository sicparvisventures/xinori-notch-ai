import SwiftUI

/// The notch silhouette: square against the top screen edge, rounded at the
/// bottom, with *inverted* (concave) corners at the top where it meets the
/// menu bar. Those two concave curves are what make the overlay read as part
/// of the hardware rather than as a floating window.
///
/// The concave corners bleed `topRadius` points outside `rect` horizontally,
/// so give this shape horizontal padding when you lay it out.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    /// Animating the *shape* (not just opacity or scale) is what sells the morph.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = min(topRadius, rect.height / 2)
        let bottom = min(bottomRadius, rect.height / 2, rect.width / 2)

        // Top-left concave corner, sweeping in from the menu bar.
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + top),
                          control: CGPoint(x: rect.minX, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + top, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))

        path.closeSubpath()
        return path
    }
}
