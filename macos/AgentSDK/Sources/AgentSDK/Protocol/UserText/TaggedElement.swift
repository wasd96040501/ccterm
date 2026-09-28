import Foundation

/// One element of the markup the CLI writes into user text:
/// `<name attribute="value">body</name>`.
///
/// Bodies are raw text the CLI mostly does not escape, so this is not XML.
/// Elements are read the way the CLI reads them: a body runs to the matching
/// close tag, past elements of the same name nested in it; names are ASCII,
/// in any case. Anything else — an unclosed tag, a self-closing one, an
/// attribute without a quoted value — is not an element.
struct TaggedElement: Equatable {
    /// Lowercased.
    var name: String
    var attributes: [String: String]
    var body: Substring

    /// The body without surrounding whitespace.
    var text: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Substring {
    /// The elements this text is made of, one after another with only
    /// whitespace between them, or `nil` if it holds anything else.
    var taggedElements: [TaggedElement]? {
        var elements: [TaggedElement] = []
        var rest = drop(while: \.isWhitespace)
        while !rest.isEmpty {
            guard let (element, end) = rest.leadingElement() else { return nil }
            elements.append(element)
            rest = rest[end...].drop(while: \.isWhitespace)
        }
        return elements.isEmpty ? nil : elements
    }

    /// The elements at the top level of this text, skipping the text around
    /// them. What is inside an element is its own.
    var topLevelElements: [TaggedElement] {
        var elements: [TaggedElement] = []
        var cursor = startIndex
        while let open = self[cursor...].firstIndex(of: "<") {
            if let (element, end) = self[open...].leadingElement() {
                elements.append(element)
                cursor = end
            } else {
                cursor = index(after: open)
            }
        }
        return elements
    }

    /// The element this text starts with, and the index past its close tag.
    func leadingElement() -> (element: TaggedElement, end: Index)? {
        guard first == "<" else { return nil }
        let name = dropFirst().prefix { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "-" || $0 == "_" }
        guard name.first?.isLetter == true, let tagEnd = self[name.endIndex...].firstIndex(of: ">"),
            let attributes = self[name.endIndex..<tagEnd].attributes,
            case let bodyStart = index(after: tagEnd), let close = self[bodyStart...].closeTag(of: name)
        else { return nil }
        let element = TaggedElement(
            name: name.lowercased(), attributes: attributes, body: self[bodyStart..<close.lowerBound])
        return (element, close.upperBound)
    }

    /// The `name="value"` pairs this text is made of, or `nil` if it holds
    /// anything else. Empty text has none.
    private var attributes: [String: String]? {
        var attributes: [String: String] = [:]
        var rest = self
        while !rest.isEmpty {
            guard rest.first?.isWhitespace == true else { return nil }
            rest = rest.drop(while: \.isWhitespace)
            if rest.isEmpty { break }
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let name = rest[..<equals]
            let quote = rest.index(after: equals)
            guard !name.isEmpty, !name.contains(where: \.isWhitespace), rest[quote...].first == "\"",
                let valueEnd = rest[rest.index(after: quote)...].firstIndex(of: "\"")
            else { return nil }
            attributes[String(name)] = String(rest[rest.index(after: quote)..<valueEnd])
            rest = rest[rest.index(after: valueEnd)...]
        }
        return attributes
    }

    /// The close tag that ends an element named `name` whose body starts this
    /// text, past any elements of the same name nested in it.
    private func closeTag(of name: Substring) -> Range<Index>? {
        var depth = 0
        var cursor = startIndex
        while let close = self[cursor...].range(ofTag: "</\(name)>") {
            var open = cursor
            while let next = self[open..<close.lowerBound].range(ofTag: "<\(name)") {
                if let after = self[next.upperBound...].first, after == ">" || after.isWhitespace { depth += 1 }
                open = next.upperBound
            }
            if depth == 0 { return close }
            depth -= 1
            cursor = close.upperBound
        }
        return nil
    }

    /// The first `tag` — `<name` or `</name>`, ASCII — in this text, in any
    /// case. Bodies can be long: `range(of:options: .caseInsensitive)` folds
    /// every character of them, and a Swift loop over their bytes is slow
    /// unoptimized, so this jumps between `<`s with `memchr` and compares
    /// with `strncasecmp`.
    private func range(ofTag tag: String) -> Range<Index>? {
        let length = tag.utf8.count
        var contiguous = self  // `withUTF8` may copy a bridged string into native storage.
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
        let lower = utf8.index(startIndex, offsetBy: offset)
        return lower..<utf8.index(lower, offsetBy: length)
    }
}
