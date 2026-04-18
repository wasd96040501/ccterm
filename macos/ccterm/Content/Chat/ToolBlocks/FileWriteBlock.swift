import SwiftUI

/// Tool block for the `Write` tool — header shows the target path (and a
/// "(new file)" suffix when `originalContent` is nil). Body shows a unified
/// diff against `originalContent` when present, otherwise the full new
/// content as a monospaced code block.
struct FileWriteBlock: View {
    let filePath: String
    let content: String
    /// `nil` when this is a new file; otherwise the file's pre-write content
    /// so the body can render a diff.
    let originalContent: String?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(status: status, isExpanded: $isExpanded) {
            if let originalContent {
                NativeDiffView(
                    filePath: filePath,
                    oldString: originalContent,
                    newString: content,
                    maxHeight: 360)
            } else {
                NewFileContentView(filePath: filePath, content: content)
            }
        } label: {
            Label(labelText, systemImage: "doc.badge.plus")
        }
    }

    private var labelText: String {
        let path = filePath.truncatedPath()
        return originalContent == nil ? "\(path) (new file)" : path
    }
}

// MARK: - New file content view

private struct NewFileContentView: View {
    let filePath: String
    let content: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxEngine) private var syntaxEngine
    @State private var tokens: [SyntaxToken]?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(attributed)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .fixedSize()
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: 360)
        .scrollIndicators(.never)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: content) {
            guard let engine = syntaxEngine else { return }
            let lang = LanguageDetection.language(for: filePath)
            tokens = await engine.highlight(code: content, language: lang)
        }
    }

    private var attributed: AttributedString {
        let font = Font.system(size: 12, design: .monospaced)
        if let tokens {
            return SyntaxAttributedString.build(
                tokens: tokens, colorScheme: colorScheme, font: font)
        }
        var plain = AttributedString(content)
        plain.font = font
        plain.foregroundColor = SyntaxTheme.plainColor(colorScheme)
        return plain
    }
}

// MARK: - Previews

#Preview("New file") {
    FileWriteBlock(
        filePath: "/Users/me/project/src/NewFile.swift",
        content: """
        import Foundation

        struct NewFile {
            let name: String

            func describe() -> String {
                "NewFile(\\(name))"
            }
        }
        """,
        originalContent: nil,
        status: .idle
    )
    .padding()
    .frame(width: 640)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Overwrite existing") {
    FileWriteBlock(
        filePath: "/Users/me/project/src/Config.swift",
        content: """
        let apiVersion = "v2"
        let baseURL = URL(string: "https://api.example.com/v2")!
        """,
        originalContent: """
        let apiVersion = "v1"
        let baseURL = URL(string: "https://api.example.com/v1")!
        """,
        status: .idle
    )
    .padding()
    .frame(width: 640)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Running") {
    FileWriteBlock(
        filePath: "/Users/me/project/src/Foo.swift",
        content: "",
        originalContent: nil,
        status: .running
    )
    .padding()
    .frame(width: 640)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Error") {
    FileWriteBlock(
        filePath: "/readonly/path/file.txt",
        content: "new content",
        originalContent: nil,
        status: .error("Write failed: read-only file system")
    )
    .padding()
    .frame(width: 640)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
