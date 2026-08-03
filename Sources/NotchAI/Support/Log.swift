import Foundation

/// stderr logging. `scripts/run.sh` pipes this to `build/NotchAI.log`, which is
/// the only way to see what happened when a run ends in an abort rather than an
/// error — the audio and speech stack fails that way more often than not.
enum Log {
    static func write(_ message: String) {
        FileHandle.standardError.write(Data("NotchAI: \(message)\n".utf8))
    }
}
