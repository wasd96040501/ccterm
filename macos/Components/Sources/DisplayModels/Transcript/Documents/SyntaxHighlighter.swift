import Foundation

/// Colours a line of source, one line at a time — keywords, strings, comments,
/// numbers, types, calls — enough that a file reads as code in a document
/// without a language server. Swift's keywords for `.swift`; a C-family set
/// for everything else; `#` comments for the scripting languages.
public nonisolated enum SyntaxHighlighter {
    public static func spans(in line: String, path: String?) -> [LineSpan] {
        let ext = ((path ?? "") as NSString).pathExtension.lowercased()
        let hashComments = ["py", "sh", "bash", "zsh", "rb", "yml", "yaml", "toml", "mk", "pl"].contains(ext)
        let keywords = ext == "swift" ? swiftKeywords : commonKeywords
        let units = Array(line.utf16)
        var spans: [LineSpan] = []
        var index = 0
        var previous: UInt16 = 0
        func isIdentifierStart(_ c: UInt16) -> Bool { c == 95 || (65...90).contains(c) || (97...122).contains(c) }
        func isIdentifier(_ c: UInt16) -> Bool { isIdentifierStart(c) || (48...57).contains(c) }
        while index < units.count {
            let c = units[index]
            let start = index
            if (c == 47 && index + 1 < units.count && units[index + 1] == 47) || (hashComments && c == 35) {
                spans.append(LineSpan(range: start..<units.count, style: .comment))
                break
            } else if c == 34 || (c == 39 && ext != "swift") || (c == 96 && ext != "swift") {
                index += 1
                while index < units.count, units[index] != c {
                    index += units[index] == 92 ? 2 : 1
                }
                index = min(index + 1, units.count)
                spans.append(LineSpan(range: start..<index, style: .string))
            } else if (48...57).contains(c), !isIdentifier(previous) {
                while index < units.count, isIdentifier(units[index]) || units[index] == 46 { index += 1 }
                spans.append(LineSpan(range: start..<index, style: .number))
            } else if isIdentifierStart(c) {
                while index < units.count, isIdentifier(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                let next: UInt16 = index < units.count ? units[index] : 0
                if keywords.contains(word) {
                    spans.append(LineSpan(range: start..<index, style: .keyword))
                } else if (65...90).contains(c) {
                    spans.append(LineSpan(range: start..<index, style: .type))
                } else if previous == 46 || next == 40 {
                    spans.append(LineSpan(range: start..<index, style: .function))
                }
            } else {
                index += 1
            }
            if index > start { previous = units[index - 1] }
        }
        return spans
    }

    private static let swiftKeywords: Set<String> = Set(
        """
        import let var func return if else guard for in while switch case default private public internal \
        fileprivate static final class struct enum extension protocol init self Self nil true false override lazy \
        didSet willSet some any throws try await async where as is defer break continue do catch throw actor \
        nonisolated weak unowned typealias associatedtype
        """.split(separator: " ").map(String.init))

    private static let commonKeywords: Set<String> = Set(
        """
        import from export const let var function return if else for while switch case default class struct enum \
        interface type public private protected static final new this super null nil true false def fn func \
        async await try catch throw throws in is as do end elif then fi done using namespace package void int \
        pub mut impl use mod
        """.split(separator: " ").map(String.init))
}
