import Foundation

/// Toggleable hot-path trace for `NativeTranscript2`. Off by default —
/// the perf-demo view flips it on while mounted so the cell / entry
/// draw / view-for / sync-subview-plan hot paths emit info-level
/// entries under category `Transcript2Perf`, and standard scroll
/// traffic on real sessions stays silent.
///
/// Every production-side call site is wrapped in `#if DEBUG`, so a
/// Release build carries **zero** trace code in the hot paths. The
/// flag + facade themselves stay always-available so the perf-demo
/// view (which itself ships in every build, but is only reachable
/// through the `#if DEBUG` sidebar entry) compiles in Release without
/// `#if DEBUG`-fencing every reference.
///
/// `log stream --predicate 'subsystem == "com.ccterm.app" && category == "Transcript2Perf"' --info`
/// from a terminal correlates frame-time spikes during scroll with
/// exactly which cells / entry views repainted.
enum Transcript2PerfLog {
    /// Demo-driven trace switch. Single-process flag; demo `.task` sets
    /// it true on appear and false on disappear. `nonisolated(unsafe)`
    /// because the hot paths reading it run on MainActor by contract;
    /// no cross-thread writes. Never flipped in Release builds — the
    /// only writer is the perf-demo view, gated by `#if DEBUG` at the
    /// sidebar dispatch.
    nonisolated(unsafe) static var enabled: Bool = false

    /// Fast-path no-op when disabled — keeps the `@autoclosure`
    /// argument unevaluated so message construction (string interp,
    /// `Date()`, etc.) doesn't run on every scroll tick. Production
    /// hot paths wrap the *call* in `#if DEBUG` rather than relying on
    /// this guard alone, so Release builds skip even the flag check.
    @inline(__always)
    static func trace(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        appLog(.info, "Transcript2Perf", message())
    }
}
