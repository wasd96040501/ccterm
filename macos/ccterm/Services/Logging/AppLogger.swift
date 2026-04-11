import Foundation
import OSLog

// MARK: - LogLevel

enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARNING"
        case .error: "ERROR"
        }
    }

    var icon: String {
        switch self {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - LogEntry

struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
}

// MARK: - AppLogger

@Observable
@MainActor
final class AppLogger {
    static let shared = AppLogger()

    private(set) var entries: [LogEntry] = []
    private(set) var categories: Set<String> = []

    private let bufferCapacity = 10_000

    private init() {}

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > bufferCapacity {
            entries.removeFirst(entries.count - bufferCapacity)
        }
        categories.insert(entry.category)
    }

    func clear() {
        entries.removeAll()
    }
}

// MARK: - Global Convenience

/// Log a message. Thread-safe — can be called from any thread.
/// Writes to both the in-app log viewer and macOS unified logging.
func appLog(_ level: LogLevel, _ category: String, _ message: String) {
    let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ccterm.app",
        category: category
    )
    osLogger.log(level: level.osLogType, "\(message, privacy: .public)")

    let entry = LogEntry(
        id: UUID(),
        timestamp: Date(),
        level: level,
        category: category,
        message: message
    )
    Task { @MainActor in
        AppLogger.shared.append(entry)
    }
}
