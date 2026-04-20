import SwiftUI

/// Tool block for the `Grep` tool — header is caller-supplied; body shows
/// matching filenames and (when available) the inline content preview.
struct GrepBlock: View {
    let title: String
    let pattern: String
    let filenames: [String]
    let content: String?
    let numFiles: Int?
    let numMatches: Int?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !filenames.isEmpty || content?.isEmpty == false
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !filenames.isEmpty {
                    FilenameList(filenames: filenames)
                }
                if let content, !content.isEmpty {
                    ContentPreview(text: content)
                }
            }
        } label: {
            Label(title, systemImage: "magnifyingglass")
        }
    }
}

// MARK: - Subviews

private struct FilenameList: View {
    let filenames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(filenames, id: \.self) { name in
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ContentPreview: View {
    let text: String

    var body: some View {
        ScrollView([.vertical]) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 260)
        .toolBlockSecondarySectionStyle()
    }
}

// MARK: - Previews

#Preview("Idle with filenames") {
    GrepBlock(
        title: "Searched \"pattern\"",
        pattern: "TODO",
        filenames: [
            "/Users/me/project/src/Foo.swift",
            "/Users/me/project/src/Bar.swift",
            "/Users/me/project/tests/FooTests.swift",
        ],
        content: nil,
        numFiles: 3,
        numMatches: 7,
        status: .idle
    )
    .padding()
    .frame(width: 560, height: 260, alignment: .topLeading)
}

#Preview("Idle with content preview") {
    GrepBlock(
        title: "Searched \"pattern\"",
        pattern: "func greet",
        filenames: [
            "/Users/me/project/src/Greeter.swift",
        ],
        content: "/Users/me/project/src/Greeter.swift:\n  12: func greet(name: String) {\n  27: func greet(name: String, greeting: String) {",
        numFiles: 1,
        numMatches: 2,
        status: .idle
    )
    .padding()
    .frame(width: 560, height: 260, alignment: .topLeading)
}

#Preview("Running") {
    GrepBlock(
        title: "Searched \"pattern\"",
        pattern: "import Foundation",
        filenames: [],
        content: nil,
        numFiles: nil,
        numMatches: nil,
        status: .running
    )
    .padding()
    .frame(width: 560, height: 260, alignment: .topLeading)
}

#Preview("Error") {
    GrepBlock(
        title: "Searched \"pattern\"",
        pattern: "[invalid(regex",
        filenames: [],
        content: nil,
        numFiles: nil,
        numMatches: nil,
        status: .error("regex parse error: missing ')'")
    )
    .padding()
    .frame(width: 560, height: 260, alignment: .topLeading)
}

#Preview("Empty — no matches") {
    GrepBlock(
        title: "Searched \"pattern\"",
        pattern: "zzzxxxqqq",
        filenames: [],
        content: nil,
        numFiles: 0,
        numMatches: 0,
        status: .idle
    )
    .padding()
    .frame(width: 560, height: 260, alignment: .topLeading)
}
