import SwiftUI

/// Native SwiftUI bash command view with syntax highlighting via highlight.js (JSCore).
struct NativeBashView: View {
    let command: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxEngine) private var syntaxEngine

    @State private var tokens: [SyntaxToken]?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(attributedContent)
                .font(.system(size: 12, design: .monospaced))
                .fontWeight(.bold)
                .lineSpacing(3)
                .fixedSize()
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
        }
        .defaultScrollAnchor(.topLeading)
        .scrollIndicators(.never)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: command) {
            guard let engine = syntaxEngine else { return }
            let code = cleanedCommand
            let result = await engine.highlight(code: code, language: "bash")
            tokens = result
        }
    }

    private var cleanedCommand: String {
        command.replacingOccurrences(
            of: "\\x1b\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression)
    }

    private var attributedContent: AttributedString {
        let font = Font.system(size: 12, design: .monospaced)

        // Prompt
        var prompt = AttributedString("$ ")
        prompt.foregroundColor = .primary.opacity(0.5)
        prompt.font = font

        if let tokens {
            let highlighted = SyntaxAttributedString.build(
                tokens: tokens, colorScheme: colorScheme, font: font)
            return prompt + highlighted
        } else {
            // Fallback: plain text before engine is ready
            var plain = AttributedString(cleanedCommand)
            plain.foregroundColor = SyntaxTheme.plainColor(colorScheme)
            plain.font = font
            return prompt + plain
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 27/255, green: 31/255, blue: 38/255)
            : Color(.sRGB, red: 129/255, green: 139/255, blue: 152/255, opacity: 31/255)
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
