import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(os)
import os
#endif

/// One reading of how much memory this process is using.
public struct MemorySample: Equatable, Identifiable {
    public let id = UUID()
    /// What had just happened when this was taken.
    public let label: String
    /// `phys_footprint`, the number iOS actually kills apps over.
    public let footprintBytes: Int64
    /// How much more this process may allocate before Jetsam intervenes, when the OS
    /// will tell us. Zero when unavailable.
    public let availableBytes: Int64

    public init(label: String, footprintBytes: Int64, availableBytes: Int64) {
        self.label = label
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
    }

    public var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    public var availableMB: Double { Double(availableBytes) / 1_048_576 }
}

/// Reads this process's memory footprint.
///
/// **`phys_footprint`, not `resident_size`.** They are different numbers and only one of
/// them matters: `phys_footprint` is what iOS's Jetsam compares against the per-process
/// limit when deciding whom to kill, and it counts compressed and IOKit-mapped memory
/// that `resident_size` does not. An app can sit at a comfortable-looking resident size
/// and still be killed. The desktop harness measured Windows working-set, which is a
/// third thing again -- so its ~22 MB-per-switch figure was never directly comparable to
/// anything the device does, and this exists to replace it with a number that is.
public enum MemoryProbe {

    public static func currentFootprint() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        // Returning 0 rather than a guess: a fabricated number here would be read as a
        // measurement, and a measurement we cannot take should look like one we did not.
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
        #else
        return 0
        #endif
    }

    /// Headroom before Jetsam. iOS only, and the more useful of the two numbers: it is
    /// the distance to being killed rather than the distance from zero.
    public static func availableMemory() -> Int64 {
        #if os(iOS)
        return Int64(os_proc_available_memory())
        #else
        return 0
        #endif
    }

    public static func sample(_ label: String) -> MemorySample {
        MemorySample(
            label: label,
            footprintBytes: currentFootprint(),
            availableBytes: availableMemory()
        )
    }
}

/// A running record of samples, and the growth between them.
///
/// The question this exists to answer is not "how much memory does the app use" but
/// "does each game switch leak, and how fast" -- the desktop harness said ~22 MB per
/// switch with no plateau, which if true on device puts a ceiling on how many games can
/// be opened in one session. Deltas between successive *library* samples are the figure
/// that matters, because that is the state the app returns to.
public final class MemoryLog {

    public private(set) var samples: [MemorySample] = []

    public init() {}

    public func record(_ label: String) {
        samples.append(MemoryProbe.sample(label))
    }

    /// Appends a pre-built sample. Exists so tests can replay a real device trace
    /// exactly; a live allocation cannot be made to reproduce a specific history.
    public func inject(_ sample: MemorySample) {
        samples.append(sample)
    }

    /// Growth between the first and last sample carrying the same label prefix.
    ///
    /// Keyed on a label prefix rather than on sample count because the interesting
    /// comparison is like-for-like: library-to-library, not library-to-game.
    public func growth(forLabelPrefix prefix: String) -> (count: Int, deltaBytes: Int64)? {
        let matching = samples.filter { $0.label.hasPrefix(prefix) }
        guard matching.count >= 2,
              let first = matching.first,
              let last = matching.last else { return nil }
        return (matching.count, last.footprintBytes - first.footprintBytes)
    }

    /// Mean growth per return to the library, in steady state.
    ///
    /// **The first sample is excluded, and that is the whole point of this function.**
    ///
    /// Sample 1 is taken when the overlay installs, roughly a second into launch, while
    /// the engine is still starting and before any game has ever been loaded. Measured on
    /// device it was about 85 MB, against roughly 425 MB once the engine is up. Averaging
    /// from it folds one-off engine startup into a per-switch figure and overstates the
    /// leak enormously: the first device run reported "+73.3 MB per library visit" when
    /// consecutive steady-state visits were 426, 426, 435, 451 -- about 8 MB.
    ///
    /// A number that is wrong by 9x in the alarming direction is not a conservative
    /// estimate, it is a bad instrument. It would have justified a design change nothing
    /// in the data called for.
    public func meanGrowthPerCycle(labelPrefix: String) -> Double? {
        let matching = samples.filter { $0.label.hasPrefix(labelPrefix) }

        // Need three: one to discard as the pre-engine baseline, then two to compare.
        guard matching.count >= 3 else { return nil }

        let steady = Array(matching.dropFirst())
        guard let first = steady.first, let last = steady.last, steady.count >= 2 else {
            return nil
        }

        let delta = last.footprintBytes - first.footprintBytes
        return Double(delta) / Double(steady.count - 1) / 1_048_576
    }
}
