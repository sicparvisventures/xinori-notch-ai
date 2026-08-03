import SwiftUI

/// Three dots breathing in sequence while we wait for the first token.
struct ThinkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .opacity(opacity(for: index))
            }
        }
        .frame(height: 16)
        .task {
            // A plain repeating animation on opacity would restart on every
            // SwiftUI update; driving one continuous phase keeps it smooth.
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let distance = (phase - Double(index)).truncatingRemainder(dividingBy: 3)
        let normalized = distance < 0 ? distance + 3 : distance
        return 0.25 + 0.55 * max(0, 1 - normalized)
    }
}
