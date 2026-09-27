import Foundation

/// Splits bare URLs out of plain text into `.link` inlines — GFM's extended
/// autolink extension, reimplemented.
///
/// Four shapes link, and they are exactly the ones the GFM spec lists:
/// `http://…`, `https://…`, anything beginning `www.`, and an e-mail address.
/// **A bare domain does not.** That is the spec's rule rather than a house
/// preference, and it happens to be the one a transcript wants: `socket.io`,
/// `sentry.io` and `deno.land` read as package names, not destinations. (Nor is
/// `NSDataDetector` fooled by filenames — it declines `README.md`, `main.py`,
/// `build.sh` and `config.json`, despite each ending in what is technically a
/// TLD.)
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
        // Every accepted shape contains one of these three, so most paragraphs
        // bail out here without the detector ever running.
        guard text.contains("://") || text.contains("@") || text.contains("ww")
        else { return [.text(text)] }
        guard let detector = Self.detector else { return [.text(text)] }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = detector.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [MarkdownIR.InlineNode] = []
        var cursor = 0
        for match in matches {
            var range = match.range
            trimTrailingPunctuation(&range, in: ns)
            guard range.length > 0, range.location >= cursor else { continue }

            let matched = ns.substring(with: range)
            guard let destination = destination(for: matched, detected: match.url) else { continue }

            if range.location > cursor {
                let head = ns.substring(
                    with: NSRange(location: cursor, length: range.location - cursor))
                result.append(.text(head))
            }
            // The matched text is what shows; only the destination may differ
            // from it, and only for the two shapes that carry no scheme.
            result.append(.link(destination: destination, title: nil, children: [.text(matched)]))
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

    /// Where a matched run points, or `nil` when GFM would not link it at all.
    ///
    /// Decided from the **matched text** rather than from `NSDataDetector`'s
    /// normalised `URL`, because the detector reports `example.com` and
    /// `www.example.com` identically — both as `http://…` — and only the source
    /// spelling separates the one GFM links from the one it leaves alone. The
    /// `URL` is consulted for one thing: telling an address from a host, which
    /// the detector already knows and which re-deriving would mean writing an
    /// e-mail grammar.
    private static func destination(for matched: String, detected: URL?) -> String? {
        let lowered = matched.lowercased()

        // Already absolute — and `trimTrailingPunctuation` has just removed a
        // character that normalising through `detected` would hand back.
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("mailto:")
        {
            return matched
        }

        // GFM's extended www autolink: the literal prefix is the whole
        // qualification, and the destination it produces carries a scheme the
        // source never had.
        if lowered.hasPrefix("www.") { return "http://" + matched }

        if detected?.scheme?.lowercased() == "mailto" { return "mailto:" + matched }

        // A bare domain. GFM leaves it as text, and so do we.
        return nil
    }

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
