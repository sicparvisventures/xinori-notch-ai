import SwiftUI

/// The execution trace, collapsed by default.
///
/// Closed it is one line — enough to see that three specialists ran without the
/// conversation turning into a log. Open it is the only way to find out why an
/// answer is wrong, which with delegation is otherwise unanswerable.
struct TraceView: View {
    let steps: [TraceStep]
    @State private var expanded = false

    private var total: TimeInterval {
        guard let first = steps.first?.startedAt else { return 0 }
        let last = steps.compactMap(\.finishedAt).max() ?? Date()
        return last.timeIntervalSince(first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(summaryLine)
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                    if total > 0 {
                        Text(String(format: "%.1f s", total))
                            .font(.system(size: 9.5, design: .monospaced))
                    }
                }
                .foregroundStyle(.white.opacity(0.42))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(colour(for: step.state))
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.82))
                                Text(step.detail)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.38))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 6)
                            Text(step.durationText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 4)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 1)
                        .padding(.leading, 2)
                }
            }
        }
    }

    private var summaryLine: String {
        let names = steps.map(\.label).joined(separator: " · ")
        return steps.count == 1 ? names : "\(steps.count) specialisten — \(names)"
    }

    private func colour(for state: TraceStep.State) -> Color {
        switch state {
        case .running: return .white.opacity(0.45)
        case .done: return .green.opacity(0.8)
        case .failed: return .orange.opacity(0.85)
        }
    }
}
