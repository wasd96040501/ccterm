import Foundation

/// GFM footnotes, done outside the parser because the parser cannot do them.
///
/// cmark-gfm has a footnote extension; swift-markdown has no footnote node at
/// all — not a dropped case, an absent one — so `[^1]` reaches `MarkdownParser`
/// as ordinary text and `[^1]: …` as an ordinary paragraph. Recovering them
/// means bracketing the parse: lift the definitions out of the source before it
/// runs, and split the references out of the text after.
///
/// Two decisions worth stating, both GitHub's:
///
/// - **Numbered by first reference, not by definition order.** `[^b]` referred
///   to first is footnote 1 however far down its definition sits — which is what
///   makes the numbers read in the order a reader meets them.
/// - **A definition nothing refers to does not render.** It is scaffolding for a
///   reference that was edited away; printing it would put a numberless note
///   under a rule for no reason. A *reference* with no definition does the
///   opposite and stays as literal text, because dropping it would silently lose
///   a word the author wrote.
enum MarkdownFootnotes {

    // MARK: - Lifting definitions out of the source

    /// Splits `source` into the body to parse and the definitions found in it,
    /// keyed by label.
    ///
    /// Definition lines are **blanked rather than removed**, so every line the
    /// body keeps stays on the line it started on. `MarkdownParser.isTight(_:)`
    /// reads source line numbers, and shifting them here would make a list's
    /// rhythm depend on whether the document happened to carry footnotes.
    static func split(_ source: String) -> (body: String, definitions: [String: String]) {
        guard source.contains("[^") else { return (source, [:]) }

        var body: [String] = []
        var definitions: [String: [String]] = [:]
        var current: String?

        for line in source.components(separatedBy: "\n") {
            // A definition starts a block, never continues one. Requiring a blank
            // line above is what keeps a paragraph that merely happens to contain
            // `[^1]:` from being torn in half.
            if current != nil || body.last?.isBlank ?? true,
                let header = definitionHeader(line)
            {
                current = header.label
                definitions[header.label, default: []].append(header.rest)
                body.append("")
                continue
            }

            if let label = current {
                // A blank line does not end a definition — an indented line after
                // it continues one, which is how a note holds two paragraphs.
                if line.isBlank || line.isIndented {
                    definitions[label]?.append(line.dedented)
                    body.append("")
                    continue
                }
                current = nil
            }

            body.append(line)
        }

        return (
            body.joined(separator: "\n"),
            definitions.mapValues { $0.joined(separator: "\n") }
        )
    }

    /// `[^label]: rest`, with up to three leading spaces — CommonMark's tolerance
    /// for an indented block start, which GFM inherits.
    private static func definitionHeader(_ line: String) -> (label: String, rest: String)? {
        var rest = Substring(line)
        var indent = 0
        while indent < 3, rest.first == " " {
            rest = rest.dropFirst()
            indent += 1
        }

        guard rest.hasPrefix("[^") else { return nil }
        rest = rest.dropFirst(2)

        guard let close = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.startIndex..<close]
        // A label with whitespace in it is not one; this is a line of prose that
        // opens with a bracket.
        guard !label.isEmpty, !label.contains(where: \.isWhitespace) else { return nil }

        let after = rest[rest.index(after: close)...]
        guard after.hasPrefix(":") else { return nil }

        return (String(label), String(after.dropFirst()).trimmingLeadingSpaces)
    }

    // MARK: - Splitting references out of the parsed tree

    /// Resolves `[^label]` references against `definitions`, numbering as it
    /// goes, and parses the definitions that earned a number.
    ///
    /// The definitions are walked too, so a note may refer to another note. The
    /// loop terminates because a label is numbered at most once, and there are
    /// finitely many.
    static func resolve(
        _ blocks: [MarkdownIR.BlockNode], definitions: [String: String]
    ) -> MarkdownIR.Document {
        guard !definitions.isEmpty else {
            return MarkdownIR.Document(blocks: blocks, footnotes: [])
        }

        var numbering = Numbering(definitions: definitions)
        let body = blocks.map { rewrite($0, &numbering) }

        var notes: [MarkdownIR.Document.Footnote] = []
        var next = 0
        while next < numbering.order.count {
            let label = numbering.order[next]
            next += 1
            let parsed = MarkdownParser.fragment(definitions[label] ?? "")
            notes.append(
                MarkdownIR.Document.Footnote(
                    number: next,
                    label: label,
                    blocks: parsed.map { rewrite($0, &numbering) }))
        }

        return MarkdownIR.Document(blocks: body, footnotes: notes)
    }

    /// Which number a label carries, assigning one the first time it is asked.
    /// `nil` for a label nothing defines — the reference stays text.
    private struct Numbering {
        let definitions: [String: String]

        private(set) var order: [String] = []
        private var numbers: [String: Int] = [:]

        init(definitions: [String: String]) {
            self.definitions = definitions
        }

        mutating func number(for label: String) -> Int? {
            guard definitions[label] != nil else { return nil }
            if let existing = numbers[label] { return existing }
            order.append(label)
            numbers[label] = order.count
            return order.count
        }
    }

    private static func rewrite(
        _ node: MarkdownIR.BlockNode, _ numbering: inout Numbering
    ) -> MarkdownIR.BlockNode {
        switch node {
        case .paragraph(let inlines):
            return .paragraph(rewrite(inlines, &numbering))

        case .heading(let level, let inlines):
            return .heading(level: level, inlines: rewrite(inlines, &numbering))

        case .blockquote(let children):
            return .blockquote(children.map { rewrite($0, &numbering) })

        case .list(let list):
            var numberingCopy = numbering
            let items = list.items.map { item in
                MarkdownIR.List.Item(
                    checkbox: item.checkbox,
                    content: item.content.map { rewrite($0, &numberingCopy) })
            }
            numbering = numberingCopy
            return .list(
                MarkdownIR.List(
                    ordered: list.ordered, startIndex: list.startIndex, isTight: list.isTight,
                    items: items))

        case .table(let table):
            var numberingCopy = numbering
            let resolved = MarkdownIR.Table(
                header: table.header.map { rewrite($0, &numberingCopy) },
                alignments: table.alignments,
                rows: table.rows.map { row in row.map { rewrite($0, &numberingCopy) } })
            numbering = numberingCopy
            return .table(resolved)

        // Neither holds inlines, so neither can hold a reference.
        case .codeBlock, .thematicBreak:
            return node
        }
    }

    private static func rewrite(
        _ inlines: [MarkdownIR.InlineNode], _ numbering: inout Numbering
    ) -> [MarkdownIR.InlineNode] {
        var result: [MarkdownIR.InlineNode] = []
        for inline in inlines {
            switch inline {
            case .text(let string):
                result.append(contentsOf: references(in: string, &numbering))
            case .emphasis(let children):
                result.append(.emphasis(rewrite(children, &numbering)))
            case .strong(let children):
                result.append(.strong(rewrite(children, &numbering)))
            case .strikethrough(let children):
                result.append(.strikethrough(rewrite(children, &numbering)))
            case .link(let destination, let title, let children):
                result.append(
                    .link(
                        destination: destination, title: title,
                        children: rewrite(children, &numbering)))
            // A reference inside verbatim text is verbatim text; inside an image's
            // alt it has nowhere to render; the breaks hold nothing.
            case .code, .image, .lineBreak, .softBreak, .footnoteReference:
                result.append(inline)
            }
        }
        return result
    }

    /// Splits `[^label]` runs out of one string. Returns the string unchanged —
    /// as a single `.text` — when it holds no reference that resolves.
    private static func references(
        in text: String, _ numbering: inout Numbering
    ) -> [MarkdownIR.InlineNode] {
        guard text.contains("[^") else { return [.text(text)] }

        var result: [MarkdownIR.InlineNode] = []
        var pending = ""
        var rest = Substring(text)

        while let open = rest.range(of: "[^") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "]") else { break }

            let label = after[after.startIndex..<close]
            guard !label.isEmpty, !label.contains(where: \.isWhitespace),
                let number = numbering.number(for: String(label))
            else {
                // Not a reference, or one nothing defines. Keep the brackets and
                // carry on past them.
                pending += rest[rest.startIndex..<open.upperBound]
                rest = after
                continue
            }

            pending += rest[rest.startIndex..<open.lowerBound]
            if !pending.isEmpty {
                result.append(.text(pending))
                pending = ""
            }
            result.append(.footnoteReference(label: String(label), number: number))
            rest = after[after.index(after: close)...]
        }

        pending += rest
        if !pending.isEmpty { result.append(.text(pending)) }
        return result.isEmpty ? [.text(text)] : result
    }
}

extension String {

    fileprivate var isBlank: Bool { allSatisfy(\.isWhitespace) }

    /// Four spaces or a tab — the indent that continues a definition, which is
    /// the same one that continues a list item.
    fileprivate var isIndented: Bool { hasPrefix("    ") || hasPrefix("\t") }

    fileprivate var dedented: String {
        if hasPrefix("\t") { return String(dropFirst()) }
        if hasPrefix("    ") { return String(dropFirst(4)) }
        return self
    }

    fileprivate var trimmingLeadingSpaces: String {
        String(drop(while: { $0 == " " }))
    }
}
