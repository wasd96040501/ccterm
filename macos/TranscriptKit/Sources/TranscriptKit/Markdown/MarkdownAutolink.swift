import Foundation

/// Splits bare URLs out of plain text into `.link` inlines.
///
/// Only `http://` and `https://` survive the filter. `NSDataDetector` also
/// reports bare domains and e-mail addresses, but in a transcript those read
/// more often as a package or module name than as something worth clicking —
/// `socket.io`, `sentry.io`, `deno.land` — while genuine URLs in model output
/// essentially always carry a scheme. Filenames turn out not to be a concern
/// either way: the detector declines `README.md`, `main.py`, `build.sh` and
/// `config.json`, despite each ending in what is technically a TLD.
///
/// `MarkdownParser` must not call this inside `[…](url)` — that would nest a
/// link within a link.
///
/// swift-markdown could in principle spare us this: cmark-gfm ships an
/// `autolink` extension, and `cmark_gfm_core_extensions_ensure_registered()`
/// registers it. But `CommonMarkConverter` attaches only `table`,
/// `strikethrough` and `tasklist`, and `ParseOptions` exposes no way to add
/// others — still true on `main`, and tracked upstream by issues #23 and #134,
/// both open. If either lands, this file can go.
enum MarkdownAutolink {

    /// Returns a single `.text` when nothing matches, otherwise an alternating
    /// `.text` / `.link` sequence covering the whole input.
    static func split(_ text: String) -> [MarkdownIR.InlineNode] {
        // Both accepted schemes contain "://", so most paragraphs bail out
        // here without the detector ever running.
        guard text.contains("://") else { return [.text(text)] }
        guard let detector = Self.detector else { return [.text(text)] }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = detector.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [MarkdownIR.InlineNode] = []
        var cursor = 0
        for match in matches {
            guard let scheme = match.url?.scheme?.lowercased() else { continue }
            guard scheme == "http" || scheme == "https" else { continue }

            var range = match.range
            trimTrailingPunctuation(&range, in: ns)
            guard range.length > 0, range.location >= cursor else { continue }

            if range.location > cursor {
                let head = ns.substring(
                    with: NSRange(location: cursor, length: range.location - cursor))
                result.append(.text(head))
            }
            // The matched text is its own destination. The scheme filter above
            // guarantees it is already absolute, so normalising through
            // `match.url` would buy nothing — and would give back exactly the
            // character `trimTrailingPunctuation` just removed.
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

    /// `NSDataDetector` inherits from `NSRegularExpression`, whose
    /// `matches(in:options:range:)` Apple documents as thread-safe — so one
    /// shared instance is fine, and saves rebuilding it per paragraph.
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Hands back the only two trailing characters the detector over-claims.
    ///
    /// Measured rather than assumed. It already drops a trailing `.` `,` `;`
    /// `!` `"` `'` and their CJK counterparts, drops enclosing `(…)` `[…]`
    /// `{…}` `<…>`, and correctly *keeps* brackets that belong to the path
    /// (`…/wiki_(thing)`). The two it swallows are `?` and `:`.
    ///
    /// Before deleting this as over-engineering, run `a https://x.com? b` and
    /// `a https://x.com: b` through the detector and look at the match.
    private static func trimTrailingPunctuation(_ range: inout NSRange, in text: NSString) {
        while range.length > 0 {
            let lastIndex = range.location + range.length - 1
            switch text.substring(with: NSRange(location: lastIndex, length: 1)) {
            case "?", ":":
                range.length -= 1
            default:
                return
            }
        }
    }
}
