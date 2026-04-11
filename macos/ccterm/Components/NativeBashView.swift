import SwiftUI

// MARK: - BashToken

struct BashToken {
    enum TokenType { case plain, string, variable, comment }
    let text: String
    let type: TokenType
}

/// Native SwiftUI bash command view with syntax highlighting.
/// Replaces WebView-based BashApp for permission cards — no async loading, no race conditions.
struct NativeBashView: View {
    let tokens: [BashToken]

    @Environment(\.colorScheme) private var colorScheme

    /// Convenience initializer that tokenizes a raw command string.
    /// Use `init(tokens:)` with precomputed tokens for cached paths.
    init(command: String) {
        let clean = command.replacingOccurrences(
            of: "\\x1b\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression)
        self.tokens = BashHighlighter.tokenize(clean)
    }

    init(tokens: [BashToken]) {
        self.tokens = tokens
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            (promptText + highlightedText)
                .font(.system(size: 12, design: .monospaced))
                .fontWeight(.bold)
                .lineSpacing(3)
                .fixedSize()
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
        }
        .scrollIndicators(.automatic)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var highlightedText: Text {
        tokens.reduce(Text("")) { result, token in
            result + Text(token.text).foregroundStyle(BashHighlighter.color(token.type, colorScheme))
        }
    }

    private var promptText: Text {
        Text("$ ").foregroundStyle(.primary.opacity(0.5))
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 27/255, green: 31/255, blue: 38/255)
            : Color(.sRGB, red: 129/255, green: 139/255, blue: 152/255, opacity: 31/255)
    }
}

// MARK: - Syntax Highlighting

enum BashHighlighter {

    static func tokenize(_ input: String) -> [BashToken] {
        guard !input.isEmpty else { return [] }

        var tokens: [BashToken] = []
        let chars = Array(input)
        let n = chars.count
        var i = 0
        var buf = ""

        func flush(_ type: BashToken.TokenType) {
            guard !buf.isEmpty else { return }
            tokens.append(BashToken(text: buf, type: type))
            buf = ""
        }

        while i < n {
            let c = chars[i]

            switch c {
            // Single-quoted string
            case "'":
                flush(.plain)
                buf.append(c); i += 1
                while i < n, chars[i] != "'" { buf.append(chars[i]); i += 1 }
                if i < n { buf.append(chars[i]); i += 1 }
                flush(.string)

            // Double-quoted string
            case "\"":
                flush(.plain)
                buf.append(c); i += 1
                while i < n, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < n {
                        buf.append(chars[i]); buf.append(chars[i + 1]); i += 2
                    } else {
                        buf.append(chars[i]); i += 1
                    }
                }
                if i < n { buf.append(chars[i]); i += 1 }
                flush(.string)

            // Backtick command substitution
            case "`":
                flush(.plain)
                buf.append(c); i += 1
                while i < n, chars[i] != "`" { buf.append(chars[i]); i += 1 }
                if i < n { buf.append(chars[i]); i += 1 }
                flush(.string)

            // Variable / $'...' ANSI-C string
            case "$":
                flush(.plain)
                buf.append(c); i += 1
                guard i < n else { flush(.variable); continue }

                let next = chars[i]
                if next == "'" {
                    // $'...' ANSI-C quoting → string color
                    buf.append(next); i += 1
                    while i < n, chars[i] != "'" {
                        if chars[i] == "\\", i + 1 < n {
                            buf.append(chars[i]); buf.append(chars[i + 1]); i += 2
                        } else {
                            buf.append(chars[i]); i += 1
                        }
                    }
                    if i < n { buf.append(chars[i]); i += 1 }
                    flush(.string)
                } else if next == "{" {
                    // ${...}
                    buf.append(next); i += 1
                    while i < n, chars[i] != "}" { buf.append(chars[i]); i += 1 }
                    if i < n { buf.append(chars[i]); i += 1 }
                    flush(.variable)
                } else if next == "(" {
                    // $(...)
                    buf.append(next); i += 1
                    var depth = 1
                    while i < n, depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        else if chars[i] == ")" { depth -= 1 }
                        buf.append(chars[i]); i += 1
                    }
                    flush(.variable)
                } else if next.isLetter || next == "_" {
                    // $var_name
                    while i < n, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                        buf.append(chars[i]); i += 1
                    }
                    flush(.variable)
                } else if "?!#@*-$".contains(next) || next.isNumber {
                    // $?, $!, $#, $@, $*, $-, $$, $0-$9
                    buf.append(next); i += 1
                    flush(.variable)
                } else {
                    // Bare $ followed by something unexpected
                    flush(.plain)
                }

            // Comment: # after whitespace, semicolon, or at start of input
            case "#":
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                if prev == nil || prev!.isWhitespace || prev == ";" || prev == "(" {
                    flush(.plain)
                    while i < n, chars[i] != "\n" { buf.append(chars[i]); i += 1 }
                    flush(.comment)
                } else {
                    buf.append(c); i += 1
                }

            // Escape in plain context
            case "\\":
                if i + 1 < n { buf.append(c); buf.append(chars[i + 1]); i += 2 }
                else { buf.append(c); i += 1 }

            default:
                buf.append(c); i += 1
            }
        }

        flush(.plain)
        return tokens
    }

    // MARK: Theme Colors (github / github-dark-dimmed)

    static func color(_ type: BashToken.TokenType, _ scheme: ColorScheme) -> Color {
        switch type {
        case .plain:
            scheme == .dark
                ? Color(.sRGB, red: 173/255, green: 186/255, blue: 199/255) // #adbac7
                : Color(.sRGB, red: 36/255, green: 41/255, blue: 47/255)    // #24292f
        case .string:
            scheme == .dark
                ? Color(.sRGB, red: 150/255, green: 208/255, blue: 255/255) // #96d0ff
                : Color(.sRGB, red: 10/255, green: 48/255, blue: 105/255)   // #0a3069
        case .variable:
            scheme == .dark
                ? Color(.sRGB, red: 246/255, green: 157/255, blue: 80/255)  // #f69d50
                : Color(.sRGB, red: 149/255, green: 56/255, blue: 0/255)    // #953800
        case .comment:
            scheme == .dark
                ? Color(.sRGB, red: 118/255, green: 131/255, blue: 144/255) // #768390
                : Color(.sRGB, red: 110/255, green: 119/255, blue: 129/255) // #6e7781
        }
    }
}

// MARK: - Previews

#Preview("Simple command") {
    NativeBashView(command: "ls -la /usr/local/bin")
        .padding()
}

#Preview("Strings & pipe") {
    NativeBashView(command: #"cat README.md | grep -i "installation" | head -20"#)
        .padding()
}

#Preview("Variables") {
    NativeBashView(command: "echo $HOME && cd ${PROJECT_DIR}/build")
        .padding()
}

#Preview("Long command — scroll") {
    NativeBashView(command: "find /usr/local -name '*.dylib' -type f -exec ls -la {} \\; | sort -k5 -n -r | head -20")
        .padding()
        .frame(width: 300)
}

#Preview("Multi-line") {
    NativeBashView(command: "docker run \\\n  --name myapp \\\n  -p 8080:80 \\\n  -v $HOME/data:/data \\\n  nginx:latest")
        .padding()
}

#Preview("Comment") {
    NativeBashView(command: "make build # Build the project")
        .padding()
}

#Preview("Dark mode") {
    VStack(spacing: 12) {
        NativeBashView(command: #"git commit -m "Fix bug""#)
        NativeBashView(command: "echo $HOME && ls -la")
        NativeBashView(command: "make build # Build the project")
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light mode") {
    VStack(spacing: 12) {
        NativeBashView(command: #"git commit -m "Fix bug""#)
        NativeBashView(command: "echo $HOME && ls -la")
        NativeBashView(command: "make build # Build the project")
    }
    .padding()
    .preferredColorScheme(.light)
}
