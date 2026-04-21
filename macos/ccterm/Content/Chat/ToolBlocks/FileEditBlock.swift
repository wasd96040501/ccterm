import SwiftUI

/// Tool block for the `Edit` tool — header is caller-supplied; body shows
/// the unified diff between `oldString` and `newString`.
struct FileEditBlock: View {
    let title: String
    let filePath: String
    let oldString: String
    let newString: String
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !oldString.isEmpty || !newString.isEmpty
        ) {
            NativeDiffView(
                filePath: filePath,
                oldString: oldString,
                newString: newString,
                maxHeight: 360)
        } label: {
            Label(title, systemImage: "pencil")
        }
    }
}

// MARK: - Previews

#Preview("Small single-hunk edit") {
    FileEditBlock(
        title: "Edited RootView.swift",
        filePath: "/Users/me/Source/ccterm/macos/ccterm/App/RootView.swift",
        oldString: "var body: some View {\n    Text(\"hello\")\n}",
        newString: "var body: some View {\n    Text(\"hello, world\")\n        .font(.title)\n}",
        status: .idle
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Running") {
    FileEditBlock(
        title: "Editing Foo.swift",
        filePath: "/Users/me/project/src/Foo.swift",
        oldString: "",
        newString: "",
        status: .running
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Error") {
    FileEditBlock(
        title: "Edited hosts",
        filePath: "/etc/hosts",
        oldString: "127.0.0.1 localhost",
        newString: "127.0.0.1 localhost\n::1 localhost",
        status: .error("Permission denied")
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Multi-line swift change") {
    FileEditBlock(
        title: "Edited App.swift",
        filePath: "/Users/me/project/Sources/App.swift",
        oldString: """
        func greet(name: String) {
            print("Hello, \\(name)")
        }
        """,
        newString: """
        func greet(name: String, greeting: String = "Hello") {
            let message = "\\(greeting), \\(name)!"
            print(message)
        }
        """,
        status: .idle
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
