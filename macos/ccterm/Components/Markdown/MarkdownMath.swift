import Foundation

enum MarkdownMath {
    /// Represents a chunk of source text that is either raw markdown or an isolated
    /// block math segment. Used as the first pass before swift-markdown parses the
    /// remaining markdown ranges.
    enum Chunk: Equatable {
        case markdown(String)
        case mathBlock(String)
    }

    /// Split the source into markdown and isolated `$$...$$` block math chunks.
    ///
    /// Block math must appear on its own line(s): preceded by a blank line (or start
    /// of input) and followed by a blank line (or end of input). Otherwise it is
    /// left as raw markdown and picked up later by the inline math pass.
    static func splitByBlockMath(_ source: String) -> [Chunk] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var chunks: [Chunk] = []
        var buffer: [String] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: "\n")
            chunks.append(.markdown(joined))
            buffer.removeAll()
        }

        var i = 0
        while i < lines.count {
            let canStartHere = buffer.isEmpty || buffer.last?.trimmingCharacters(in: .whitespaces).isEmpty == true
            if canStartHere, let (content, next) = tryParseBlockMath(lines, from: i) {
                while let last = buffer.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    buffer.removeLast()
                }
                flushBuffer()
                chunks.append(.mathBlock(content))
                i = next
                if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }
            buffer.append(lines[i])
            i += 1
        }
        flushBuffer()
        return chunks
    }

    private static func tryParseBlockMath(_ lines: [String], from start: Int) -> (String, Int)? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("$$") else { return nil }

        let afterOpen = String(first.dropFirst(2))

        // Same-line $$...$$
        if afterOpen.hasSuffix("$$"), afterOpen.count >= 2 {
            let nextBlank = (start + 1 >= lines.count) || lines[start + 1].trimmingCharacters(in: .whitespaces).isEmpty
            guard nextBlank else { return nil }
            let content = String(afterOpen.dropLast(2))
            return (content.trimmingCharacters(in: .whitespaces), start + 1)
        }

        // Multi-line block
        var contentLines: [String] = []
        if !afterOpen.isEmpty {
            contentLines.append(afterOpen)
        }
        var j = start + 1
        while j < lines.count {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("$$") {
                let nextBlank = (j + 1 >= lines.count) || lines[j + 1].trimmingCharacters(in: .whitespaces).isEmpty
                guard nextBlank else { return nil }
                let beforeClose = String(trimmed.dropLast(2))
                if !beforeClose.isEmpty {
                    contentLines.append(beforeClose)
                }
                let joined = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return (joined, j + 1)
            }
            contentLines.append(lines[j])
            j += 1
        }
        return nil
    }

    /// Scan a plain text string (a single Text node's content) for inline `$...$` math
    /// and return an alternating sequence of text and inlineMath nodes.
    ///
    /// Conservative rules: delimiters are single `$`, content is non-empty, contains
    /// no newline, and is not immediately preceded/followed by a digit (to avoid
    /// matching prices). Escaped `\$` is treated as a literal `$` and does not open
    /// or close a run.
    static func splitInlineMath(in text: String) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var literal = ""
        let chars = Array(text)
        var i = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            result.append(.text(literal))
            literal = ""
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                literal.append("$")
                i += 2
                continue
            }

            if c == "$" {
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                if let p = prev, p.isNumber {
                    literal.append(c)
                    i += 1
                    continue
                }

                // Scan ahead for the closing $
                var j = i + 1
                var inner = ""
                var closed = false
                while j < chars.count {
                    let cj = chars[j]
                    if cj == "\n" { break }
                    if cj == "\\", j + 1 < chars.count, chars[j + 1] == "$" {
                        inner.append("$")
                        j += 2
                        continue
                    }
                    if cj == "$" {
                        let after: Character? = j + 1 < chars.count ? chars[j + 1] : nil
                        if let a = after, a.isNumber {
                            inner.append(cj)
                            j += 1
                            continue
                        }
                        closed = true
                        break
                    }
                    inner.append(cj)
                    j += 1
                }

                if closed, !inner.isEmpty {
                    flushLiteral()
                    result.append(.inlineMath(inner))
                    i = j + 1
                    continue
                }
            }

            literal.append(c)
            i += 1
        }

        flushLiteral()
        return result
    }
}
