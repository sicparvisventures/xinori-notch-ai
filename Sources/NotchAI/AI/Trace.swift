import Foundation

/// One line in the execution trace.
///
/// Without this a delegated answer is a black box: three models ran, some tools
/// fired, and if the answer is wrong there is nowhere to look. The trace is the
/// difference between debugging and guessing.
struct TraceStep: Identifiable, Equatable, Sendable {
    enum State: Sendable { case running, done, failed }

    let id = UUID()
    var label: String
    var detail: String
    var state: State
    var startedAt: Date
    var finishedAt: Date?

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var durationText: String {
        guard let duration else { return "" }
        return duration < 1
            ? String(format: "%.0f ms", duration * 1000)
            : String(format: "%.1f s", duration)
    }
}
