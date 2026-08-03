import SwiftUI

/// A live "working on it" indicator: a breathing orb and a highlight sweeping
/// across the label.
///
/// Driven by `TimelineView(.animation)` rather than `withAnimation`. The panel
/// puts an `.animation(...)` modifier on its whole tree for the open/close
/// morph, which swallows implicit animations started inside it — that is why
/// the previous dots sat still. A timeline redraws on the display's own clock
/// and is immune to that.
struct ThinkingIndicator: View {
    var label: String

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 8) {
                orb(at: time)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sweep(at: time))
                    .animation(nil, value: label)
            }
            .frame(height: 18)
        }
    }

    /// A soft pulse rather than a spinner: it reads as "alive" without
    /// implying a measurable progress bar.
    private func orb(at time: TimeInterval) -> some View {
        let pulse = (sin(time * 2.4) + 1) / 2          // 0…1
        return ZStack {
            Circle()
                .fill(.white.opacity(0.12 + 0.10 * pulse))
                .frame(width: 14 + 4 * pulse, height: 14 + 4 * pulse)
            Circle()
                .fill(.white.opacity(0.55 + 0.35 * pulse))
                .frame(width: 6, height: 6)
        }
        .frame(width: 18, height: 18)
    }

    /// A bright band travelling left to right through dim text. The gradient
    /// stops move with time, so the highlight glides instead of stepping.
    private func sweep(at time: TimeInterval) -> LinearGradient {
        let period = 1.8
        let phase = (time.truncatingRemainder(dividingBy: period)) / period   // 0…1
        // Travel from fully off-screen left to fully off-screen right so the
        // band never pops in or out mid-word.
        let centre = phase * 2.2 - 0.6

        return LinearGradient(
            stops: [
                .init(color: .white.opacity(0.32), location: 0),
                .init(color: .white.opacity(0.32), location: max(0, centre - 0.22)),
                .init(color: .white.opacity(0.95), location: min(1, max(0, centre))),
                .init(color: .white.opacity(0.32), location: min(1, centre + 0.22)),
                .init(color: .white.opacity(0.32), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
