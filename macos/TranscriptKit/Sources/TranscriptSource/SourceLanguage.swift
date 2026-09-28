import Foundation

/// What the lexer needs to know about a language to colour it the way Xcode
/// does: its keywords and how it writes comments, strings and attributes.
///
/// A table, not a grammar. Xcode colours from its index — a project type in
/// one colour, a system type in another — and a read-only view of a file out
/// of its project has no index, so neither does Xcode then: an unresolved name
/// is plain. What a table can know is what the lexer colours: keywords,
/// literals, comments, attributes, preprocessor lines, and the name a
/// declaration introduces.
public struct SourceLanguage: Sendable, Equatable {
    public var name: String
    var keywords: Set<String>
    /// Keywords after which the next identifier is a type being declared
    /// (Xcode's `declaration.type`).
    var typeDeclarators: Set<String>
    /// Keywords after which the next identifier is anything else being
    /// declared (Xcode's `declaration.other`).
    var otherDeclarators: Set<String>
    var lineComments: [String]
    var blockComment: (open: String, close: String)?
    /// Comment openers Xcode draws as documentation (proportional type).
    var docComments: [String]
    /// Quote characters; a tripled quote opens a multi-line string where the
    /// language has one.
    var quotes: [Character]
    var hasTripleQuotedStrings: Bool
    /// `@MainActor` in Swift, `@Override` in Java, decorators in Python.
    var attributePrefix: Character?
    /// `#include`, `#if` — a `#` that starts a directive, not a comment.
    var hasPreprocessor: Bool
    /// `\(…)` inside a string is code, not string.
    var interpolation: String?

    public static func == (lhs: SourceLanguage, rhs: SourceLanguage) -> Bool { lhs.name == rhs.name }

    /// No colouring: output, logs, text.
    public static let plainText = SourceLanguage(
        name: "Plain Text", keywords: [], typeDeclarators: [], otherDeclarators: [], lineComments: [],
        blockComment: nil, docComments: [], quotes: [], hasTripleQuotedStrings: false, attributePrefix: nil,
        hasPreprocessor: false, interpolation: nil)

    /// The language a file's name says it is written in; plain text when it
    /// says nothing this table knows.
    public static func forPath(_ path: String) -> SourceLanguage {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if let language = byExtension[ext] { return language }
        switch name {
        case "Makefile", "makefile", "GNUmakefile", "Dockerfile", ".zshrc", ".bashrc", ".profile": return shell
        case "Package.swift": return swift
        default: return plainText
        }
    }

    private static let byExtension: [String: SourceLanguage] = {
        var table: [String: SourceLanguage] = [:]
        for ext in ["swift"] { table[ext] = swift }
        for ext in ["c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh", "metal"] { table[ext] = cFamily }
        for ext in ["js", "jsx", "ts", "tsx", "mjs", "cjs"] { table[ext] = javaScript }
        for ext in ["py", "pyi"] { table[ext] = python }
        for ext in ["go"] { table[ext] = go }
        for ext in ["rs"] { table[ext] = rust }
        for ext in ["java", "kt", "kts", "scala", "cs"] { table[ext] = java }
        for ext in ["sh", "bash", "zsh", "fish", "command"] { table[ext] = shell }
        for ext in ["rb"] { table[ext] = ruby }
        for ext in ["json", "jsonl"] { table[ext] = json }
        for ext in ["yml", "yaml", "toml", "ini", "cfg", "conf", "xcconfig"] { table[ext] = config }
        return table
    }()

    public static let swift = SourceLanguage(
        name: "Swift",
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
            "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
            "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
            "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
            "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws",
            "true", "try", "async", "actor", "any", "some", "convenience", "dynamic", "final", "indirect", "lazy",
            "mutating", "nonmutating", "nonisolated", "optional", "override", "required", "unowned", "weak",
            "willSet", "didSet", "get", "set", "consume", "borrowing", "consuming", "each", "macro", "package",
            "isolated", "sending",
        ],
        typeDeclarators: ["class", "struct", "enum", "protocol", "actor", "extension", "typealias", "associatedtype"],
        otherDeclarators: ["func", "var", "let", "case"],
        lineComments: ["//"], blockComment: ("/*", "*/"), docComments: ["///", "/**"], quotes: ["\""],
        hasTripleQuotedStrings: true, attributePrefix: "@", hasPreprocessor: true, interpolation: "\\(")

    public static let cFamily = SourceLanguage(
        name: "C",
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
            "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed",
            "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
            "bool", "true", "false", "NULL", "nullptr", "class", "namespace", "template", "typename", "public",
            "private", "protected", "virtual", "override", "new", "delete", "this", "using", "constexpr", "noexcept",
            "try", "catch", "throw", "self", "super", "nil", "YES", "NO", "id", "instancetype", "BOOL", "@interface",
            "@implementation", "@end", "@property", "@protocol", "nonatomic", "strong", "weak", "copy", "assign",
            "readonly", "kernel", "vertex", "fragment", "device", "constant",
        ],
        typeDeclarators: ["class", "struct", "enum", "union", "namespace", "typedef"], otherDeclarators: [],
        lineComments: ["//"], blockComment: ("/*", "*/"), docComments: ["///", "/**"], quotes: ["\"", "'"],
        hasTripleQuotedStrings: false, attributePrefix: nil, hasPreprocessor: true, interpolation: nil)

    public static let javaScript = SourceLanguage(
        name: "JavaScript",
        keywords: [
            "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
            "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
            "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
            "async", "await", "of", "from", "as", "true", "false", "null", "undefined", "static", "get", "set",
            "interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "declare",
            "namespace", "abstract", "keyof", "satisfies",
        ],
        typeDeclarators: ["class", "interface", "type", "enum", "namespace"],
        otherDeclarators: ["function", "const", "let", "var"],
        lineComments: ["//"], blockComment: ("/*", "*/"), docComments: ["/**"], quotes: ["\"", "'", "`"],
        hasTripleQuotedStrings: false, attributePrefix: "@", hasPreprocessor: false, interpolation: "${")

    public static let python = SourceLanguage(
        name: "Python",
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match",
            "case", "self",
        ],
        typeDeclarators: ["class"], otherDeclarators: ["def"],
        lineComments: ["#"], blockComment: nil, docComments: [], quotes: ["\"", "'"],
        hasTripleQuotedStrings: true, attributePrefix: "@", hasPreprocessor: false, interpolation: nil)

    public static let go = SourceLanguage(
        name: "Go",
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "true", "false", "nil", "iota",
        ],
        typeDeclarators: ["type"], otherDeclarators: ["func", "var", "const"],
        lineComments: ["//"], blockComment: ("/*", "*/"), docComments: [], quotes: ["\"", "'", "`"],
        hasTripleQuotedStrings: false, attributePrefix: nil, hasPreprocessor: false, interpolation: nil)

    public static let rust = SourceLanguage(
        name: "Rust",
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
            "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
        ],
        typeDeclarators: ["struct", "enum", "trait", "type", "impl", "mod"], otherDeclarators: ["fn", "let", "const"],
        lineComments: ["//"], blockComment: ("/*", "*/"), docComments: ["///", "//!"], quotes: ["\""],
        hasTripleQuotedStrings: false, attributePrefix: nil, hasPreprocessor: false, interpolation: nil)

    public static let java = SourceLanguage(
        name: "Java",
        keywords: [
            "abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default",
            "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements",
            "import", "instanceof", "int", "interface", "long", "new", "package", "private", "protected", "public",
            "return", "short", "static", "super", "switch", "this", "throw", "throws", "try", "void", "volatile",
            "while", "true", "false", "null", "fun", "val", "var", "object", "data", "sealed", "override", "when",
            "is", "in", "companion", "suspend", "internal", "open", "lateinit", "using", "namespace", "readonly",
        ],
        typeDeclarators: ["class", "interface", "enum", "object"], otherDeclarators: ["fun", "val", "var"],
        lineComments: ["//"], blockComment: ("/*", "*/"), docComments: ["/**"], quotes: ["\"", "'"],
        hasTripleQuotedStrings: true, attributePrefix: "@", hasPreprocessor: false, interpolation: nil)

    public static let shell = SourceLanguage(
        name: "Shell",
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
            "function", "select", "return", "exit", "export", "local", "readonly", "declare", "unset", "source",
            "alias", "set", "shift", "break", "continue", "eval", "exec", "trap", "true", "false",
        ],
        typeDeclarators: [], otherDeclarators: ["function"],
        lineComments: ["#"], blockComment: nil, docComments: [], quotes: ["\"", "'"],
        hasTripleQuotedStrings: false, attributePrefix: nil, hasPreprocessor: false, interpolation: "$(")

    public static let ruby = SourceLanguage(
        name: "Ruby",
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
            "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
            "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield",
            "require", "attr_reader", "attr_accessor",
        ],
        typeDeclarators: ["class", "module"], otherDeclarators: ["def"],
        lineComments: ["#"], blockComment: nil, docComments: [], quotes: ["\"", "'"],
        hasTripleQuotedStrings: false, attributePrefix: nil, hasPreprocessor: false, interpolation: "#{")

    public static let json = SourceLanguage(
        name: "JSON", keywords: ["true", "false", "null"], typeDeclarators: [], otherDeclarators: [],
        lineComments: [], blockComment: nil, docComments: [], quotes: ["\""], hasTripleQuotedStrings: false,
        attributePrefix: nil, hasPreprocessor: false, interpolation: nil)

    public static let config = SourceLanguage(
        name: "Configuration", keywords: ["true", "false", "null", "yes", "no", "on", "off"], typeDeclarators: [],
        otherDeclarators: [], lineComments: ["#"], blockComment: nil, docComments: [], quotes: ["\"", "'"],
        hasTripleQuotedStrings: false, attributePrefix: nil, hasPreprocessor: false, interpolation: nil)
}
