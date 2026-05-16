import Foundation

/// Splits bare URLs out of plain text into `.link` inlines. Only recognizes
/// `http://` and `https://` schemes — file paths, emails, and bare domains
/// (example.com) stay as text to avoid misidentifying code paths / filenames
/// as links.
///
/// The caller (`MarkdownConvert`) is responsible for short-circuiting this
/// inside `[…](url)` to prevent double-linkification.
enum MarkdownAutolink {
    /// Scan `text` and return either a single `.text` (no matches) or a
    /// mixed `.text` / `.link` sequence.
    static func split(_ text: String) -> [MarkdownInline] {
        guard text.contains("://") else { return [.text(text)] }
        guard let detector = Self.detector else { return [.text(text)] }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = detector.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [MarkdownInline] = []
        var cursor = 0
        for match in matches {
            guard let url = match.url else { continue }
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { continue }

            var range = match.range
            trimTrailingPunctuation(&range, in: ns)
            guard range.length > 0 else { continue }
            guard range.location >= cursor else { continue }

            if range.location > cursor {
                let head = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result.append(.text(head))
            }
            let urlText = ns.substring(with: range)
            result.append(.link(destination: urlText, children: [.text(urlText)]))
            cursor = range.location + range.length
        }

        if result.isEmpty { return [.text(text)] }
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            result.append(.text(tail))
        }
        return result
    }

    // MARK: - Private

    /// `NSDataDetector` inherits from `NSRegularExpression`; per Apple docs
    /// `matches(in:options:range:)` is thread-safe, so a shared instance is fine.
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Strip trailing punctuation from a URL match. Common sentence shapes
    /// like `visit https://x.com.` get the trailing period swallowed by the
    /// detector; return `.,;:!?` and unmatched closing brackets to the text.
    private static func trimTrailingPunctuation(_ range: inout NSRange, in text: NSString) {
        while range.length > 0 {
            let lastIdx = range.location + range.length - 1
            let last = text.substring(with: NSRange(location: lastIdx, length: 1))
            guard let ch = last.first else { break }

            switch ch {
            case ".", ",", ";", ":", "!", "?", "\"", "'":
                range.length -= 1
            case ")", "]", "}":
                let opener: Character = ch == ")" ? "(" : (ch == "]" ? "[" : "{")
                let body = text.substring(with: NSRange(location: range.location, length: range.length - 1))
                let openers = body.reduce(0) { $1 == opener ? $0 + 1 : $0 }
                let closersIn = body.reduce(0) { $1 == ch ? $0 + 1 : $0 }
                if openers > closersIn { return }
                range.length -= 1
            default:
                return
            }
        }
    }
}
