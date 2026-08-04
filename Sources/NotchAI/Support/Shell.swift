import Foundation

/// Subprocess helpers for the tools.
///
/// Read-only tools invoke executables directly with an argument array — never
/// through a shell — so an argument that happens to contain `;` or backticks is
/// data, not syntax. Only `run_shell` deliberately goes through `zsh -c`, and
/// that one is gated behind explicit confirmation.
/// Minimal shared flag between the watchdog thread and the reader.
private final class Atomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String

        var combined: String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.isEmpty { return out }
            if out.isEmpty { return err }
            return out + "\n" + err
        }
    }

    enum ShellError: LocalizedError {
        case timedOut(String)
        case failed(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case let .timedOut(command):
                return "'\(command)' reageerde niet binnen de tijdslimiet."
            case let .failed(command, status, message):
                return "'\(command)' faalde (status \(status)): \(message)"
            }
        }
    }

    /// Run an executable and return its output. Throws on a non-zero exit so a
    /// tool never reports a failure as if it were a result.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 20
    ) async throws -> String {
        let result = try await capture(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ShellError.failed(executable, result.status, result.combined)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Like `run`, but hands back the exit status instead of throwing — for
    /// tools where a non-zero exit is information rather than an error.
    static func capture(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 20
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            // Off the cooperative pool: Process blocks, and a long-running tool
            // would otherwise starve unrelated async work.
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // A watchdog, because `readDataToEndOfFile` blocks until the
                // child closes its pipes. Checking the deadline *after* those
                // reads — as this did — makes the timeout unreachable for
                // exactly the case it exists for: a child that never exits.
                // Terminating from a second thread gives the reads their EOF.
                let timedOut = Atomic(false)
                let watchdog = Thread {
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        if !process.isRunning { return }
                        usleep(50_000)
                    }
                    if process.isRunning {
                        timedOut.value = true
                        process.terminate()
                    }
                }
                watchdog.start()

                // Read before waiting: a child that fills the 64K pipe buffer
                // blocks forever if we wait for exit first.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if timedOut.value {
                    continuation.resume(throwing: ShellError.timedOut(executable))
                    return
                }

                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Run AppleScript. This is how the Mail and Calendar tools reach apps that
    /// have no other scriptable interface; the first call triggers macOS's
    /// Automation consent prompt for the target app.
    static func osascript(_ source: String, timeout: TimeInterval = 25) async throws -> String {
        let result = try await capture("/usr/bin/osascript", ["-e", source], timeout: timeout)
        guard result.status == 0 else {
            let message = result.combined
            if message.contains("-1743") || message.lowercased().contains("not authorized") {
                throw ShellError.failed(
                    "osascript", result.status,
                    "Geen Automation-toestemming. Sta NotchAI toe in Systeeminstellingen → Privacy en beveiliging → Automatisering.")
            }
            throw ShellError.failed("osascript", result.status, message)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
