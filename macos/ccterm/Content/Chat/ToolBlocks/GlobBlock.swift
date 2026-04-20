import SwiftUI

/// Tool block for the `Glob` tool — header is caller-supplied; body lists
/// matched file paths.
struct GlobBlock: View {
    let title: String
    let pattern: String
    let filenames: [String]
    let numFiles: Int?
    let truncated: Bool
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !filenames.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(filenames, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if truncated {
                    Text("… truncated")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Label(title, systemImage: "folder")
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    GlobBlock(
        title: "Globbed \"pattern\"",
        pattern: "**/*.swift",
        filenames: [
            "/Users/me/project/src/App.swift",
            "/Users/me/project/src/Config.swift",
            "/Users/me/project/src/Views/Home.swift",
            "/Users/me/project/tests/AppTests.swift",
        ],
        numFiles: 4,
        truncated: false,
        status: .idle
    )
    .padding()
    .frame(width: 560, height: 280, alignment: .topLeading)
}

#Preview("Truncated") {
    GlobBlock(
        title: "Globbed \"pattern\"",
        pattern: "**/*",
        filenames: (1...20).map { "/Users/me/project/file\($0).txt" },
        numFiles: 100,
        truncated: true,
        status: .idle
    )
    .padding()
    .frame(width: 560, height: 480, alignment: .topLeading)
}

#Preview("Running") {
    GlobBlock(
        title: "Globbed \"pattern\"",
        pattern: "**/*.tsx",
        filenames: [],
        numFiles: nil,
        truncated: false,
        status: .running
    )
    .padding()
    .frame(width: 560, height: 280, alignment: .topLeading)
}

#Preview("Error") {
    GlobBlock(
        title: "Globbed \"pattern\"",
        pattern: "[[[",
        filenames: [],
        numFiles: nil,
        truncated: false,
        status: .error("invalid glob pattern")
    )
    .padding()
    .frame(width: 560, height: 280, alignment: .topLeading)
}
