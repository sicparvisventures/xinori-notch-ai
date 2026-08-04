import Foundation

/// What this Mac can actually run.
///
/// Unified memory is the binding constraint for local inference: the whole model
/// has to be resident, and whatever is left over is what macOS and your other
/// apps get. Ignoring that is how you end up recommending a model that swaps.
enum Hardware {
    static var totalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static var chip: String {
        sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
    }

    static var cores: Int {
        ProcessInfo.processInfo.processorCount
    }

    /// Memory we're willing to hand to a model.
    ///
    /// The reserve is deliberately generous. A model that *just* fits leaves
    /// nothing for the browser and the compiler you actually had open, and the
    /// resulting swap makes inference slower than a smaller model would have
    /// been. 30% or 6 GB, whichever is larger — on a 8 GB machine that leaves
    /// very little, which is the honest answer rather than a flattering one.
    static var memoryBudget: UInt64 {
        let reserve = max(UInt64(6) << 30, UInt64(Double(totalMemory) * 0.30))
        return totalMemory > reserve ? totalMemory - reserve : 0
    }

    static var summary: String {
        let gb = Double(totalMemory) / 1_073_741_824
        return String(format: "%@ · %.0f GB geheugen", chip, gb)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
