import Foundation

/// Parsed-out parts of a `sed -i 's/pattern/replacement/flags' file`
/// command. Built by `SedEditParser.parse` — only the subset of sed
/// that fits a single substitution survives. Anything else (multiple
/// expressions, alternate delimiters, glob args) returns `nil` and
/// the rendering layer falls back to showing the raw shell command.
struct SedEditInfo: Equatable {
    var filePath: String
    var pattern: String
    var replacement: String
    var flags: String
    var extendedRegex: Bool
}

/// Pure-Swift port of the upstream `sedEditParser.ts` covering the
/// patterns Bash agents actually emit:
///
///   sed -i 's/foo/bar/g' file
///   sed -i '' 's/foo/bar/g' file        # macOS form with empty suffix
///   sed -i.bak 's/foo/bar/g' file
///   sed -E -i 's/foo+/bar/g' file
///
/// Edge cases that aren't worth the complexity (alternate delimiters,
/// chained `-e` expressions, address ranges, glob args) return `nil`
/// and the caller falls back to the shell body. The parser is pure —
/// it never reads the filesystem; substitution application lives on
/// `SedEditInfo.apply(to:)`.
enum SedEditParser {

    /// Returns the substitution + target file extracted from `command`
    /// when it's a single `sed -i ...` substitution. Otherwise `nil`.
    static func parse(_ command: String) -> SedEditInfo? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("sed ") || trimmed.hasPrefix("sed\t") else {
            return nil
        }
        let withoutSed = trimmed.dropFirst("sed".count)
        guard let tokens = ShellTokenizer.tokenize(String(withoutSed)) else {
            return nil
        }

        var hasInPlaceFlag = false
        var extendedRegex = false
        var expression: String? = nil
        var filePath: String? = nil

        var i = 0
        while i < tokens.count {
            let arg = tokens[i]

            if arg == "-i" || arg == "--in-place" {
                hasInPlaceFlag = true
                i += 1
                if i < tokens.count {
                    let next = tokens[i]
                    // macOS sed -i requires a backup suffix; an empty
                    // string or a dot-prefixed extension qualifies.
                    if !next.hasPrefix("-")
                        && (next.isEmpty || next.hasPrefix("."))
                    {
                        i += 1
                    }
                }
                continue
            }
            if arg.hasPrefix("-i") {
                hasInPlaceFlag = true
                i += 1
                continue
            }
            if arg == "-E" || arg == "-r" || arg == "--regexp-extended" {
                extendedRegex = true
                i += 1
                continue
            }
            if arg == "-e" || arg == "--expression" {
                guard i + 1 < tokens.count else { return nil }
                if expression != nil { return nil }
                expression = tokens[i + 1]
                i += 2
                continue
            }
            if arg.hasPrefix("--expression=") {
                if expression != nil { return nil }
                expression = String(arg.dropFirst("--expression=".count))
                i += 1
                continue
            }
            if arg.hasPrefix("-") {
                return nil
            }
            // First non-flag arg = expression; second = file path.
            // Anything beyond that is multi-file sed, which we don't
            // try to render.
            if expression == nil {
                expression = arg
            } else if filePath == nil {
                filePath = arg
            } else {
                return nil
            }
            i += 1
        }

        guard hasInPlaceFlag,
            let expression,
            let filePath
        else {
            return nil
        }

        guard let parts = parseSubstitution(expression) else {
            return nil
        }
        return SedEditInfo(
            filePath: filePath,
            pattern: parts.pattern,
            replacement: parts.replacement,
            flags: parts.flags,
            extendedRegex: extendedRegex)
    }

    /// Splits `s/pattern/replacement/flags` honouring `\/` escapes.
    /// Returns `nil` for any other expression form so the caller
    /// falls back to the literal command.
    private static func parseSubstitution(
        _ expression: String
    )
        -> (pattern: String, replacement: String, flags: String)?
    {
        guard expression.hasPrefix("s/") else { return nil }
        let rest = expression.dropFirst(2)
        enum State { case pattern, replacement, flags }
        var state: State = .pattern
        var pattern = ""
        var replacement = ""
        var flags = ""
        var idx = rest.startIndex
        while idx < rest.endIndex {
            let ch = rest[idx]
            if ch == "\\", rest.index(after: idx) < rest.endIndex {
                let next = rest[rest.index(after: idx)]
                switch state {
                case .pattern:
                    pattern.append(ch)
                    pattern.append(next)
                case .replacement:
                    replacement.append(ch)
                    replacement.append(next)
                case .flags:
                    flags.append(ch)
                    flags.append(next)
                }
                idx = rest.index(idx, offsetBy: 2)
                continue
            }
            if ch == "/" {
                switch state {
                case .pattern: state = .replacement
                case .replacement: state = .flags
                case .flags: return nil
                }
                idx = rest.index(after: idx)
                continue
            }
            switch state {
            case .pattern: pattern.append(ch)
            case .replacement: replacement.append(ch)
            case .flags: flags.append(ch)
            }
            idx = rest.index(after: idx)
        }
        guard state == .flags else { return nil }
        // Only allow safe substitution flags — bail out on anything
        // exotic so we don't have to model side-effecting ones (w, e).
        let allowed = CharacterSet(charactersIn: "gpimIM123456789")
        if !flags.isEmpty,
            flags.unicodeScalars.contains(where: { !allowed.contains($0) })
        {
            return nil
        }
        return (pattern, replacement, flags)
    }
}

extension SedEditInfo {
    /// Apply this substitution to `content` via `NSRegularExpression`
    /// and return the resulting text. Mirrors
    /// `applySedSubstitution` upstream but stays inside Foundation —
    /// no third-party regex.
    ///
    /// Returns the unchanged `content` if the regex fails to compile
    /// (same fallback upstream uses). The card body then shows a
    /// zero-line diff, which still conveys "this is the file the
    /// agent wants to edit" without misleading the user.
    func apply(to content: String) -> String {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") || flags.contains("I") {
            options.insert(.caseInsensitive)
        }
        if flags.contains("m") || flags.contains("M") {
            options.insert(.anchorsMatchLines)
        }

        let pattern = sedPatternToICU(self.pattern, extendedRegex: extendedRegex)
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: options)
        else {
            return content
        }
        let template = sedReplacementToICU(self.replacement)
        let range = NSRange(content.startIndex..., in: content)
        if flags.contains("g") {
            return regex.stringByReplacingMatches(
                in: content,
                options: [],
                range: range,
                withTemplate: template)
        }
        guard
            let first = regex.firstMatch(
                in: content, options: [], range: range)
        else {
            return content
        }
        let nsContent = content as NSString
        let replaced = regex.replacementString(
            for: first,
            in: content,
            offset: 0,
            template: template)
        let mutable = NSMutableString(string: nsContent)
        mutable.replaceCharacters(in: first.range, with: replaced)
        return mutable as String
    }

    /// Convert a sed pattern to ICU regex syntax. In BRE mode (no
    /// `-E`), `\+ \? \| \( \)` are metacharacters and the bare forms
    /// are literal — opposite of ICU/PCRE. ERE matches ICU directly,
    /// so we only rewrite for the BRE case. Identical algorithm to
    /// the upstream placeholder dance.
    private func sedPatternToICU(_ pattern: String, extendedRegex: Bool) -> String {
        // sed-specific escape \/ → /
        var p = pattern.replacingOccurrences(of: "\\/", with: "/")
        guard !extendedRegex else { return p }
        // Use sentinel placeholders so the swap doesn't collide with
        // the next phase's escaping.
        let bs = "\u{0000}BS\u{0000}"
        let plus = "\u{0000}PL\u{0000}"
        let q = "\u{0000}QU\u{0000}"
        let pipe = "\u{0000}PI\u{0000}"
        let lp = "\u{0000}LP\u{0000}"
        let rp = "\u{0000}RP\u{0000}"
        p = p.replacingOccurrences(of: "\\\\", with: bs)
        p = p.replacingOccurrences(of: "\\+", with: plus)
        p = p.replacingOccurrences(of: "\\?", with: q)
        p = p.replacingOccurrences(of: "\\|", with: pipe)
        p = p.replacingOccurrences(of: "\\(", with: lp)
        p = p.replacingOccurrences(of: "\\)", with: rp)
        p = p.replacingOccurrences(of: "+", with: "\\+")
        p = p.replacingOccurrences(of: "?", with: "\\?")
        p = p.replacingOccurrences(of: "|", with: "\\|")
        p = p.replacingOccurrences(of: "(", with: "\\(")
        p = p.replacingOccurrences(of: ")", with: "\\)")
        p = p.replacingOccurrences(of: bs, with: "\\\\")
        p = p.replacingOccurrences(of: plus, with: "+")
        p = p.replacingOccurrences(of: q, with: "?")
        p = p.replacingOccurrences(of: pipe, with: "|")
        p = p.replacingOccurrences(of: lp, with: "(")
        p = p.replacingOccurrences(of: rp, with: ")")
        return p
    }

    /// Convert sed replacement syntax (`&` = match, `\&` = literal &)
    /// to ICU template syntax (`$0` = match, `\$` = literal `$`).
    private func sedReplacementToICU(_ replacement: String) -> String {
        var r = replacement.replacingOccurrences(of: "\\/", with: "/")
        // ICU templates treat `$` as backref intro and `\` as escape.
        // We need to: (1) protect literal `\&` first, (2) escape any
        // `$` in user input, (3) rewrite `&` to `$0`, (4) restore
        // literal ampersands.
        let amp = "\u{0000}AMP\u{0000}"
        r = r.replacingOccurrences(of: "\\&", with: amp)
        r = r.replacingOccurrences(of: "\\", with: "\\\\")
        r = r.replacingOccurrences(of: "$", with: "\\$")
        r = r.replacingOccurrences(of: "&", with: "$0")
        r = r.replacingOccurrences(of: amp, with: "&")
        return r
    }
}

/// Minimal shell-quote tokenizer for the sed parser. Handles the
/// quoting forms agents actually produce — single quotes (no escape
/// recognition inside), double quotes (`\"`, `\\`), and bare words.
/// Anything more exotic (process substitution, glob expansion, $())
/// returns `nil` so the caller falls back to literal display.
enum ShellTokenizer {
    static func tokenize(_ input: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var i = input.startIndex
        var inToken = false
        while i < input.endIndex {
            let ch = input[i]
            if !inSingle && !inDouble && (ch == " " || ch == "\t") {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
                i = input.index(after: i)
                continue
            }
            inToken = true
            if !inDouble && ch == "'" {
                inSingle.toggle()
                i = input.index(after: i)
                continue
            }
            if !inSingle && ch == "\"" {
                inDouble.toggle()
                i = input.index(after: i)
                continue
            }
            if !inSingle && ch == "\\", input.index(after: i) < input.endIndex {
                let next = input[input.index(after: i)]
                current.append(next)
                i = input.index(i, offsetBy: 2)
                continue
            }
            if !inSingle && !inDouble {
                // Reject characters that signal a non-trivial shell
                // construct — we can't faithfully render those, so
                // fall back to the literal-command view.
                if "$`<>|&;()*?[]{}".contains(ch) {
                    return nil
                }
            }
            current.append(ch)
            i = input.index(after: i)
        }
        if inSingle || inDouble {
            return nil
        }
        if inToken {
            tokens.append(current)
        }
        return tokens
    }
}
