import Foundation

extension UserMessage {
    /// A command the user ran in the CLI itself rather than sent to the model
    /// — a slash command such as `/compact`, or a `!` shell command — or what
    /// it printed.
    public enum LocalCommand: Sendable, Equatable {
        /// The command as entered: `/compact`, `/model opus`, `!ls`.
        case input(String)
        /// What the command printed.
        case output(standardOutput: String, standardError: String)
    }

    /// The local command this message carries, or `nil` for any other message.
    public var localCommand: LocalCommand? {
        guard let elements = taggedElements else { return nil }
        func body(_ name: String) -> String? {
            elements.first { $0.name == name }.map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let name = body("command-name") {
            let arguments = body("command-args") ?? ""
            return .input(arguments.isEmpty ? name : "\(name) \(arguments)")
        }
        if let shell = body("bash-input") { return .input("!\(shell)") }
        let standardOutput = body("local-command-stdout") ?? body("bash-stdout")
        let standardError = body("local-command-stderr") ?? body("bash-stderr")
        guard standardOutput != nil || standardError != nil else { return nil }
        return .output(standardOutput: standardOutput ?? "", standardError: standardError ?? "")
    }

    /// The note the CLI files ahead of a local command's messages, telling
    /// the model to disregard them. It is written to the session's file but
    /// never sent on the stream.
    var isLocalCommandCaveat: Bool {
        taggedElements?.map(\.name) == ["local-command-caveat"]
    }

    /// The top-level elements of a message whose whole text is the tags the
    /// CLI writes for what it sends as the user — `<name>body</name>`, one
    /// after another — or `nil` for any other message. Bodies are raw text
    /// the CLI does not escape, so this is not XML; they are read the way the
    /// CLI reads them: up to the matching close tag, ASCII names in any case.
    private var taggedElements: [(name: String, body: Substring)]? {
        guard content.count == 1, let text = content[0].text else { return nil }
        var elements: [(name: String, body: Substring)] = []
        var rest = text.drop(while: \.isWhitespace)
        while !rest.isEmpty {
            guard rest.first == "<", let tagEnd = rest.firstIndex(of: ">") else { return nil }
            let tag = rest[rest.index(after: rest.startIndex)..<tagEnd]
            let name = tag.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "-" || $0 == "_" }
            guard name.first?.isLetter == true, tag.dropFirst(name.count).first.map(\.isWhitespace) ?? true,
                let close = Self.close(of: name, in: rest[rest.index(after: tagEnd)...])
            else { return nil }
            elements.append((name.lowercased(), rest[rest.index(after: tagEnd)..<close.lowerBound]))
            rest = rest[close.upperBound...].drop(while: \.isWhitespace)
        }
        return elements.isEmpty ? nil : elements
    }

    /// The close tag that ends an element named `name` whose body starts
    /// `text`, past any elements of the same name nested in it.
    private static func close(of name: Substring, in text: Substring) -> Range<Substring.Index>? {
        var depth = 0
        var cursor = text.startIndex
        while let close = range(of: "</\(name)>", in: text[cursor...]) {
            var open = cursor
            while let next = range(of: "<\(name)", in: text[open..<close.lowerBound]) {
                if let after = text[next.upperBound...].first, after == ">" || after.isWhitespace { depth += 1 }
                open = next.upperBound
            }
            if depth == 0 { return close }
            depth -= 1
            cursor = close.upperBound
        }
        return nil
    }

    /// The first `tag` — `<name` or `</name>`, ASCII — in `text`, in any
    /// case. Bodies can be long: `range(of:options: .caseInsensitive)` folds
    /// every character of them, and a Swift loop over their bytes is slow
    /// unoptimized, so this jumps between `<`s with `memchr` and compares
    /// with `strncasecmp`.
    private static func range(of tag: String, in text: Substring) -> Range<Substring.Index>? {
        let length = tag.utf8.count
        var contiguous = text  // `withUTF8` may copy a bridged string into native storage.
        let offset = contiguous.withUTF8 { bytes -> Int? in
            guard let base = UnsafeRawPointer(bytes.baseAddress) else { return nil }
            var start = 0
            while start + length <= bytes.count,
                let open = memchr(base + start, Int32(UInt8(ascii: "<")), bytes.count - start)
            {
                let at = base.distance(to: open)
                if at + length <= bytes.count, strncasecmp(open.assumingMemoryBound(to: CChar.self), tag, length) == 0 {
                    return at
                }
                start = at + 1
            }
            return nil
        }
        guard let offset else { return nil }
        let lower = text.utf8.index(text.startIndex, offsetBy: offset)
        return lower..<text.utf8.index(lower, offsetBy: length)
    }
}
