import Foundation

/// Toggleable hot-path trace for `NativeTranscript2`. Off by default —
/// the perf-demo view flips it on while mounted so the cell/entry
/// draw / view-for / sync-subview-plan hot paths emit info-level
/// entries under category `Transcript2Perf`, and standard scroll
/// traffic on real sessions stays silent.
///
/// `log stream --predicate 'subsystem == "com.ccterm.app" && category == "Transcript2Perf"'`
/// from a terminal correlates frame-time spikes during scroll with
/// exactly which cells / entry views repainted.
enum Transcript2PerfLog {
    /// Demo-driven trace switch. Single-process flag; demo `.task` sets
    /// it true on appear and false on disappear. `nonisolated(unsafe)`
    /// because the hot paths reading it run on MainActor by contract;
    /// no cross-thread writes.
    nonisolated(unsafe) static var enabled: Bool = false

    /// Fast-path no-op when disabled — keeps the `@autoclosure`
    /// argument unevaluated so message construction (string interp,
    /// `Date()`, etc.) doesn't run on every scroll tick in release.
    @inline(__always)
    static func trace(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        appLog(.info, "Transcript2Perf", message())
    }
}
