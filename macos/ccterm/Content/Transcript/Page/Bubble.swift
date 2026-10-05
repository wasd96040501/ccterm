import Foundation

/// What a user's bubble says, worded: its text, and the runs of it set apart as
/// tokens (design/transcript/05-local.md). The page's own value — TranscriptKit's
/// `UserMessage` is made from it where a row meets the renderer
/// (`PageRow+View`), so `Page/` imports no view code.
nonisolated struct Bubble: Sendable, Equatable {
    struct Token: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// A command's name: `/model`, or the `!` of a shell command.
            case command
            /// A picture the message names — *Image 1*: the number is the
            /// prompt's, and what hovering or clicking it finds.
            case image(number: Int)
        }

        /// UTF-16 offsets into ``Bubble/text``.
        var range: Range<Int>
        var kind: Kind
        /// A skill's full name, where the token shows the short one.
        var toolTip: String?
    }

    var text: String
    var tokens: [Token] = []
    /// Held or queued: drawn at half strength.
    var isPending = false
    /// A shell command's words are set in mono.
    var isMonospaced = false
}

nonisolated extension Bubble {
    /// A slash command the reader ran: its name as a token and its
    /// arguments as ordinary text. A skill or plugin shows its short name
    /// (`/skill-creator`), the whole one as the tooltip.
    static func slash(name: String, arguments: String, isPending: Bool = false) -> Bubble {
        let title = Self.shortName(of: name)
        let text = arguments.isEmpty ? title : "\(title) \(arguments)"
        return Bubble(
            text: text,
            tokens: [
                Token(
                    range: 0..<title.utf16.count, kind: .command, toolTip: title == name ? nil : name)
            ], isPending: isPending)
    }

    /// A `!` command: the sigil as a token, a space, the command in mono
    /// (preview.js `cmdToken("!")` then the `.shellcmd`).
    static func shell(_ command: String) -> Bubble {
        Bubble(
            text: "! " + command, tokens: [Token(range: 0..<1, kind: .command, toolTip: nil)], isMonospaced: true)
    }

    /// `/skill-creator` for `/skill-creator:skill-creator`.
    static func shortName(of name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return "/" + name[name.index(after: colon)...]
    }

    /// A prompt's words: `[Image #N]` for each of `numbers` becomes the token
    /// *Image N*; and when `readsCommand` — a prompt written here, which the
    /// composer showed with its command as a token — a leading `/name` is one
    /// too. `nil` when nothing but pictures was said (the thumbnails stand alone).
    static func words(
        _ source: String, imageNumbers numbers: Set<Int>, readsCommand: Bool, isPending: Bool
    ) -> Bubble? {
        var source = source
        var tokens: [Token] = []
        if readsCommand, let name = command(in: source) {
            let short = shortName(of: name)
            source = short + source.dropFirst(name.count)
            tokens.append(
                Token(range: 0..<short.utf16.count, kind: .command, toolTip: short == name ? nil : name))
        }

        var text = ""
        var cursor = source.startIndex
        var mentioned = 0
        for match in imageMentions.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source),
                let digits = Range(match.range(at: 1), in: source), let number = Int(source[digits]),
                numbers.contains(number)
            else { continue }
            text += source[cursor..<range.lowerBound]
            let name = String(localized: "Image \(number)")
            let start = text.utf16.count
            text += name
            tokens.append(Token(range: start..<(start + name.utf16.count), kind: .image(number: number)))
            cursor = range.upperBound
            mentioned += 1
        }
        text += source[cursor...]
        // Only pictures were said: the thumbnails alone, no empty bubble.
        if mentioned > 0,
            source.replacingOccurrences(of: imageMentions.pattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return nil
        }
        return Bubble(text: text, tokens: tokens, isPending: isPending)
    }

    /// `/model` at the start of `text`: a slash, a letter, then non-space.
    private static func command(in text: String) -> String? {
        guard text.hasPrefix("/"), let second = text.dropFirst().first, second.isLetter else { return nil }
        return String(text.prefix { !$0.isWhitespace })
    }

    private static let imageMentions = try! NSRegularExpression(pattern: #"\[Image #(\d+)\]"#)
}
