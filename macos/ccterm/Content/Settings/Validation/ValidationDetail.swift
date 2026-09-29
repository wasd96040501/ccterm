import Foundation

/// The line a form shows under a field about what its check found.
struct ValidationDetail: Equatable {
    /// `nil` shows nothing.
    var text: String?
    /// Whether `text` is a problem, shown in red.
    var isError: Bool

    static let none = ValidationDetail(text: nil, isError: false)
    static let checking = ValidationDetail(text: String(localized: "Checking…"), isError: false)

    /// `reason` as a sentence, and — when something else stays in use — what.
    static func problem(_ reason: String, fallback: String?) -> ValidationDetail {
        var text = reason
        if let last = text.last, !".!?。！？".contains(last) { text += "." }
        if let fallback { text += " " + String(localized: "Still using \(fallback).") }
        return ValidationDetail(text: text, isError: true)
    }
}
