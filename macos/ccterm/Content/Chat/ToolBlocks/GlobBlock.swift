import SwiftUI

/// Tool block for the `Glob` tool — header shows the pattern and file count
/// (plus truncation flag); body lists matched file paths.
struct GlobBlock: View {
    let pattern: String
    let filenames: [String]
    let numFiles: Int?
    let truncated: Bool
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(status: status, isExpanded: $isExpanded) {
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
            Label(labelText, systemImage: "folder")
        }
    }

    private var labelText: String {
        var out = pattern
        if let numFiles { out += "  (\(numFiles) files" + (truncated ? ", truncated" : "") + ")" }
        else if truncated { out += "  (truncated)" }
        return out
    }
}

// MARK: - Previews

#Preview("Idle") {
    GlobBlock(
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
    .frame(width: 560)
}

#Preview("Truncated") {
    GlobBlock(
        pattern: "**/*",
        filenames: (1...20).map { "/Users/me/project/file\($0).txt" },
        numFiles: 100,
        truncated: true,
        status: .idle
    )
    .padding()
    .frame(width: 560)
}

#Preview("Running") {
    GlobBlock(
        pattern: "**/*.tsx",
        filenames: [],
        numFiles: nil,
        truncated: false,
        status: .running
    )
    .padding()
    .frame(width: 560)
}

#Preview("Error") {
    GlobBlock(
        pattern: "[[[",
        filenames: [],
        numFiles: nil,
        truncated: false,
        status: .error("invalid glob pattern")
    )
    .padding()
    .frame(width: 560)
}
