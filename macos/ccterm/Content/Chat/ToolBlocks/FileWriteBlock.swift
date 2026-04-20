import SwiftUI

/// Tool block for the `Write` tool — header is caller-supplied; body shows
/// a unified diff against `originalContent` when present, or the full new
/// content with line numbers + syntax highlighting (no `+` / green) when
/// the file is new.
struct FileWriteBlock: View {
    let title: String
    let filePath: String
    let content: String
    /// `nil` when this is a new file; otherwise the file's pre-write content
    /// so the body can render a diff.
    let originalContent: String?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !content.isEmpty || originalContent?.isEmpty == false
        ) {
            NativeDiffView(
                filePath: filePath,
                oldString: originalContent ?? "",
                newString: content,
                maxHeight: 360,
                suppressInsertionStyle: originalContent == nil)
        } label: {
            Label(title, systemImage: "doc.badge.plus")
        }
    }
}

// MARK: - Previews

#Preview("New file") {
    FileWriteBlock(
        title: "Wrote NewFile.swift",
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
    .frame(width: 640, height: 360, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Overwrite existing") {
    FileWriteBlock(
        title: "Wrote Config.swift",
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
    .frame(width: 640, height: 360, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Running") {
    FileWriteBlock(
        title: "Writing Foo.swift",
        filePath: "/Users/me/project/src/Foo.swift",
        content: "",
        originalContent: nil,
        status: .running
    )
    .padding()
    .frame(width: 640, height: 360, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Error") {
    FileWriteBlock(
        title: "Wrote file.txt",
        filePath: "/readonly/path/file.txt",
        content: "new content",
        originalContent: nil,
        status: .error("Write failed: read-only file system")
    )
    .padding()
    .frame(width: 640, height: 360, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
