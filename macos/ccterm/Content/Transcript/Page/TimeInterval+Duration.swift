import Foundation
import os

nonisolated extension TimeInterval {
    /// `34s`, `1m 5s`, `12m`, `1h 3m` — the resolution a reader wants at each
    /// size, in the app's language (not the system's, which the rest of the
    /// line may not be in).
    var durationText: String {
        let seconds = Int(rounded())
        return Self.durationFormatters.withLockUnchecked { formatters in
            let formatter =
                switch seconds {
                case ..<60: formatters.seconds
                case ..<600: formatters.minutesAndSeconds
                case ..<3600: formatters.minutes
                default: formatters.hoursAndMinutes
                }
            return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
        }
    }

    /// One formatter per resolution, made once: making one is most of what
    /// formatting a duration costs, and a page formats one per line. Pages
    /// build off the main actor, several at once, so they are used only
    /// inside the lock.
    private struct DurationFormatters {
        let seconds = durationFormatter([.second])
        let minutesAndSeconds = durationFormatter([.minute, .second])
        let minutes = durationFormatter([.minute])
        let hoursAndMinutes = durationFormatter([.hour, .minute])
    }

    private static let durationFormatters = OSAllocatedUnfairLock(uncheckedState: DurationFormatters())

    private static func durationFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = units
        return formatter
    }
}
