import Foundation
import OSLog

enum LogLevel: Sendable {
    case debug
    case info
    case warning
    case error

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}

/// Log a message. Thread-safe; can be called from any thread.
///
/// Explicitly `nonisolated` so background / off-main code (worktree provisioning,
/// remote ssh provisioning + credential refresh) can log without a main-actor
/// hop. The module defaults to `@MainActor` isolation
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), which would otherwise infer this global as
/// main-actor-bound; `os.Logger` is itself thread-safe, so that inference is
/// wrong for a pure logging sink.
///
/// Writes to macOS unified logging — visible in Console.app
/// (filter by subsystem `com.ccterm.app`) or via
/// `log stream --predicate 'subsystem == "com.ccterm.app"' --level debug`.
nonisolated func appLog(_ level: LogLevel, _ category: String, _ message: String) {
    let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ccterm.app",
        category: category
    )
    osLogger.log(level: level.osLogType, "\(message, privacy: .public)")
}
