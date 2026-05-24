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
/// Writes to macOS unified logging — visible in Console.app
/// (filter by subsystem `com.ccterm.app`) or via
/// `log stream --predicate 'subsystem == "com.ccterm.app"' --level debug`.
func appLog(_ level: LogLevel, _ category: String, _ message: String) {
    let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ccterm.app",
        category: category
    )
    osLogger.log(level: level.osLogType, "\(message, privacy: .public)")
}
