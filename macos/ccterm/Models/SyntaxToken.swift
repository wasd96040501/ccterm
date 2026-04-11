struct SyntaxToken {
    let text: String
    let scope: String? // "hljs-keyword" | "hljs-string" | ... | nil (plain)
}
