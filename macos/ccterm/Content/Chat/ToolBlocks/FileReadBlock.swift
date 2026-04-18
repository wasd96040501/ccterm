import SwiftUI

/// Tool block for the `Read` tool — success state is header-only (no body);
/// error state shows the banner inline via the shared shell.
struct FileReadBlock: View {
    let filePath: String
    let status: ToolBlockStatus

    var body: some View {
        ToolBlock(status: status) {
            Label(filePath.truncatedPath(), systemImage: "doc.text")
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    FileReadBlock(
        filePath: "/Users/me/Source/ccterm/macos/ccterm/App/RootView.swift",
        status: .idle
    )
    .padding()
    .frame(width: 520, height: 140, alignment: .topLeading)
}

#Preview("Running") {
    FileReadBlock(
        filePath: "/Users/me/Source/ccterm/very/long/path/to/some/deeply/nested/File.swift",
        status: .running
    )
    .padding()
    .frame(width: 520, height: 140, alignment: .topLeading)
}

#Preview("Error") {
    FileReadBlock(
        filePath: "/missing/file.txt",
        status: .error("ENOENT: no such file or directory")
    )
    .padding()
    .frame(width: 520, height: 140, alignment: .topLeading)
}

#Preview("Stacked") {
    VStack(spacing: 8) {
        FileReadBlock(filePath: "/Users/me/a.txt", status: .idle)
        FileReadBlock(filePath: "/Users/me/b.txt", status: .running)
        FileReadBlock(filePath: "/Users/me/c.txt", status: .error("permission denied"))
    }
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
}
