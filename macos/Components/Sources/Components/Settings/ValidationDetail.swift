import Foundation

/// The line a form shows under a field about what its check found.
public struct ValidationDetail: Equatable {
    /// `nil` shows nothing.
    public var text: String?
    /// Whether `text` is a problem, shown in red.
    public var isError: Bool

    public init(text: String?, isError: Bool) {
        self.text = text
        self.isError = isError
    }

    public static let none = ValidationDetail(text: nil, isError: false)
    public static let checking = ValidationDetail(text: String(localized: "Checking…", bundle: .module), isError: false)

    /// `reason` as a sentence, and — when something else stays in use — what.
    public static func problem(_ reason: String, fallback: String?) -> ValidationDetail {
        var text = reason
        if let last = text.last, !".!?。！？".contains(last) { text = String(localized: "\(reason).", bundle: .module) }
        if let fallback { text += " " + String(localized: "Still using \(fallback).", bundle: .module) }
        return ValidationDetail(text: text, isError: true)
    }
}
