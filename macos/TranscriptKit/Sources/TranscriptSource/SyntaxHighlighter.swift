import Foundation

/// A coloured span of source: a range and the Xcode syntax class it draws in.
public struct SourceToken: Sendable, Equatable {
    /// Xcode's `xcode.syntax.*` classes this lexer can tell apart.
    public enum Kind: Sendable, Equatable {
        case keyword
        case string
        case number
        case comment
        /// `///` and `/** */`: Xcode sets these in a proportional face.
        case documentationComment
        /// `// MARK:` — bold in Xcode.
        case mark
        case attribute
        case preprocessor
        /// The name a `class` / `struct` / … introduces.
        case declarationType
        /// The name a `func` / `var` / `let` introduces.
        case declarationOther
        /// A name the platform defines (`NSView`, `String`).
        case systemType
    }

    /// UTF-16 offsets into the lexed text.
    public var range: Range<Int>
    public var kind: Kind
}

/// Colours source the way Xcode does when it has no index: by lexing, one
/// pass, left to right, carrying comment and string state across lines.
///
/// It works on the whole text rather than per line because a block comment or
/// a multi-line string spans lines; its offsets are UTF-16 because that is
/// what `NSTextStorage` ranges are.
public enum SyntaxHighlighter {
    public static func tokens(in text: String, language: SourceLanguage) -> [SourceToken] {
        guard language != .plainText else { return [] }
        var lexer = Lexer(units: Array(text.utf16), language: language)
        return lexer.run()
    }
}

private struct Lexer {
    let units: [UInt16]
    let language: SourceLanguage
    var tokens: [SourceToken] = []
    var index = 0
    /// The keyword before the current identifier, for declarations.
    var declarator: String?

    init(units: [UInt16], language: SourceLanguage) {
        self.units = units
        self.language = language
    }

    mutating func run() -> [SourceToken] {
        while index < units.count {
            lexOne()
        }
        return tokens
    }

    // MARK: - Dispatch

    private mutating func lexOne() {
        let unit = units[index]
        if unit.isWhitespace {
            index += 1
            return
        }
        if lexComment() || lexPreprocessor() || lexAttribute() || lexString() || lexNumber() || lexWord() {
            return
        }
        // Punctuation ends a declaration: `case .a` names nothing.
        declarator = nil
        index += 1
    }

    // MARK: - Comments

    private mutating func lexComment() -> Bool {
        let start = index
        for opener in language.docComments where matches(opener) {
            if opener.hasPrefix("/*"), let block = language.blockComment {
                skipBlock(closingWith: block.close)
                emit(start, .documentationComment)
            } else {
                // Xcode keeps the marker in the code face; the prose after it
                // is set proportional.
                index += opener.utf16.count
                emit(start, .comment)
                let prose = index
                skipToEndOfLine()
                emit(prose, .documentationComment)
            }
            return true
        }
        for opener in language.lineComments where matches(opener) {
            // `#` is a comment only where the language has no directives.
            skipToEndOfLine()
            let text = string(start..<index)
            emit(
                start,
                text.dropFirst(opener.count).trimmingCharacters(in: .whitespaces).hasPrefix("MARK:") ? .mark : .comment)
            return true
        }
        if let block = language.blockComment, matches(block.open) {
            index += block.open.utf16.count
            skipBlock(closingWith: block.close)
            emit(start, .comment)
            return true
        }
        return false
    }

    private mutating func skipBlock(closingWith close: String) {
        if matches("/**") { index += 3 }
        while index < units.count, !matches(close) {
            index += 1
        }
        index = min(units.count, index + close.utf16.count)
    }

    // MARK: - Directives and attributes

    private mutating func lexPreprocessor() -> Bool {
        guard language.hasPreprocessor, units[index] == UInt16(ascii: "#"), index + 1 < units.count,
            units[index + 1].isIdentifierHead
        else { return false }
        let start = index
        index += 1
        skipIdentifier()
        if language == .cFamily {
            // A C directive runs to the end of its line, arguments included.
            let word = string(start..<index)
            if word == "#include" || word == "#import" {
                skipToEndOfLine()
            }
        }
        emit(start, .preprocessor)
        return true
    }

    private mutating func lexAttribute() -> Bool {
        guard let prefix = language.attributePrefix, units[index] == UInt16(prefix.asciiValue ?? 0),
            index + 1 < units.count, units[index + 1].isIdentifierHead
        else { return false }
        let start = index
        index += 1
        skipIdentifier()
        let word = string(start..<index)
        emit(start, language.keywords.contains(word) ? .keyword : .attribute)
        return true
    }

    // MARK: - Literals

    private mutating func lexString() -> Bool {
        guard let quote = language.quotes.first(where: { units[index] == UInt16($0.asciiValue ?? 0) }) else {
            return false
        }
        declarator = nil
        let q = UInt16(quote.asciiValue ?? 0)
        let tripled =
            language.hasTripleQuotedStrings && index + 2 < units.count && units[index + 1] == q
            && units[index + 2] == q
        let multiline = tripled || quote == "`"
        // Single quotes never interpolate; JavaScript interpolates only in
        // template literals.
        let interpolates = quote != "'" && (language != .javaScript || quote == "`")
        var segmentStart = index
        index += tripled ? 3 : 1
        while index < units.count {
            let unit = units[index]
            if unit == UInt16(ascii: "\\") {
                if let marker = language.interpolation, marker.hasPrefix("\\"), interpolates, matches(marker) {
                    emit(segmentStart, .string)
                    skipInterpolation(opener: marker)
                    segmentStart = index
                    continue
                }
                index += 2
                continue
            }
            if let marker = language.interpolation, !marker.hasPrefix("\\"), interpolates, matches(marker) {
                emit(segmentStart, .string)
                skipInterpolation(opener: marker)
                segmentStart = index
                continue
            }
            if unit == UInt16(ascii: "\n"), !multiline { break }
            if unit == q {
                if tripled {
                    if index + 2 < units.count, units[index + 1] == q, units[index + 2] == q {
                        index += 3
                        break
                    }
                } else {
                    index += 1
                    break
                }
            }
            index += 1
        }
        index = min(index, units.count)
        emit(segmentStart, .string)
        return true
    }

    /// Past `\(…)` / `${…}` to its matching close, leaving what is inside
    /// uncoloured — it is code, and Xcode draws it plain.
    private mutating func skipInterpolation(opener: String) {
        index += opener.utf16.count
        let open = opener.utf16.last ?? 0
        let close: UInt16 = open == UInt16(ascii: "{") ? UInt16(ascii: "}") : UInt16(ascii: ")")
        var depth = 1
        while index < units.count, depth > 0 {
            if units[index] == open { depth += 1 }
            if units[index] == close { depth -= 1 }
            if units[index] == UInt16(ascii: "\n") { return }
            index += 1
        }
    }

    private mutating func lexNumber() -> Bool {
        let unit = units[index]
        guard unit.isDigit else { return false }
        if index > 0, units[index - 1].isIdentifierBody { return false }
        let start = index
        index += 1
        while index < units.count {
            let u = units[index]
            if u.isIdentifierBody {
                index += 1
            } else if u == UInt16(ascii: "."), index + 1 < units.count, units[index + 1].isDigit {
                index += 1
            } else {
                break
            }
        }
        emit(start, .number)
        declarator = nil
        return true
    }

    // MARK: - Words

    private mutating func lexWord() -> Bool {
        guard units[index].isIdentifierHead else { return false }
        let start = index
        skipIdentifier()
        let word = string(start..<index)
        if language.keywords.contains(word) {
            emit(start, .keyword)
            declarator =
                language.typeDeclarators.contains(word) || language.otherDeclarators.contains(word) ? word : nil
            return true
        }
        if let declarator {
            emit(start, language.typeDeclarators.contains(declarator) ? .declarationType : .declarationOther)
            self.declarator = nil
            return true
        }
        if language == .swift || language == .cFamily, Self.isSystemType(word) {
            emit(start, .systemType)
        }
        return true
    }

    /// Names the platform defines, by the prefixes and the standard-library
    /// names Xcode would resolve to a system type.
    private static func isSystemType(_ word: String) -> Bool {
        if systemTypes.contains(word) { return true }
        for prefix in ["NS", "CG", "CA", "CF", "UI", "AV", "CT", "CI", "MTL", "WK", "SC", "Dispatch"]
        where word.count > prefix.count && word.hasPrefix(prefix) {
            let next = word[word.index(word.startIndex, offsetBy: prefix.count)]
            if next.isUppercase { return true }
        }
        return false
    }

    private static let systemTypes: Set<String> = [
        "String", "Substring", "Character", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
        "UInt32", "UInt64", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "Result", "Error",
        "Never", "Void", "Data", "Date", "URL", "UUID", "Task", "Range", "ClosedRange", "IndexSet", "AnyObject",
        "AnyHashable", "Sendable", "Hashable", "Equatable", "Comparable", "Codable", "Decodable", "Encodable",
        "Identifiable", "Collection", "Sequence", "MainActor", "AsyncStream", "TimeInterval", "Notification",
        "NotificationCenter", "JSONDecoder", "JSONEncoder", "FileManager", "Bundle", "ProcessInfo", "UserDefaults",
        "Timer", "Calendar", "Locale", "Decoder", "Encoder", "CustomStringConvertible", "Published", "Combine",
        "AnyCancellable", "XCTestCase",
    ]

    // MARK: - Scanning

    private func matches(_ literal: String) -> Bool {
        var i = index
        for unit in literal.utf16 {
            guard i < units.count, units[i] == unit else { return false }
            i += 1
        }
        return true
    }

    private mutating func skipToEndOfLine() {
        while index < units.count, units[index] != UInt16(ascii: "\n") {
            index += 1
        }
    }

    private mutating func skipIdentifier() {
        while index < units.count, units[index].isIdentifierBody {
            index += 1
        }
    }

    private func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    private mutating func emit(_ start: Int, _ kind: SourceToken.Kind) {
        guard index > start else { return }
        tokens.append(SourceToken(range: start..<index, kind: kind))
    }
}

extension UInt16 {
    fileprivate var isWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }

    fileprivate var isDigit: Bool { self >= 0x30 && self <= 0x39 }

    /// ASCII letters, `_`, `$`, and everything past ASCII — an identifier in
    /// every language here may hold letters no table lists.
    fileprivate var isIdentifierHead: Bool {
        (self >= 0x41 && self <= 0x5A) || (self >= 0x61 && self <= 0x7A) || self == 0x5F || self == 0x24
            || self >= 0x80
    }

    fileprivate var isIdentifierBody: Bool { isIdentifierHead || isDigit }
}

extension UInt16 {
    fileprivate init(ascii scalar: Unicode.Scalar) {
        self = UInt16(scalar.value)
    }
}
