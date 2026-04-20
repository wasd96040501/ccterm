import SwiftUI

/// Tool block for the `Read` tool — success state is header-only (no body);
/// error state shows the banner inline via the shared shell.
struct FileReadBlock: View {
    let title: String
    let filePath: String
    let status: ToolBlockStatus

    var body: some View {
        ToolBlock(status: status) {
            Label(title, systemImage: "doc.text")
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    FileReadBlock(
        title: "Read RootView.swift",
        filePath: "/Users/me/Source/ccterm/macos/ccterm/App/RootView.swift",
        status: .idle
    )
    .padding()
    .frame(width: 520, height: 140, alignment: .topLeading)
}

#Preview("Running") {
    FileReadBlock(
        title: "Reading File.swift",
        filePath: "/Users/me/Source/ccterm/very/long/path/to/some/deeply/nested/File.swift",
        status: .running
    )
    .padding()
    .frame(width: 520, height: 140, alignment: .topLeading)
}

#Preview("Error") {
    FileReadBlock(
        title: "Read file.txt",
        filePath: "/missing/file.txt",
        status: .error("ENOENT: no such file or directory")
    )
    .padding()
    .frame(width: 520, height: 140, alignment: .topLeading)
}

#Preview("Stacked") {
    VStack(spacing: 8) {
        FileReadBlock(title: "Read a.txt", filePath: "/Users/me/a.txt", status: .idle)
        FileReadBlock(title: "Reading b.txt", filePath: "/Users/me/b.txt", status: .running)
        FileReadBlock(title: "Read c.txt", filePath: "/Users/me/c.txt", status: .error("permission denied"))
    }
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
}
