import SwiftUI

/// Tool block for the `WebFetch` tool — header is caller-supplied; body
/// renders the fetched content as markdown.
struct WebFetchBlock: View {
    let title: String
    let url: String
    let httpStatus: Int?
    let result: String?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: result?.isEmpty == false
        ) {
            if let result, !result.isEmpty {
                ScrollView([.vertical]) {
                    MarkdownView(result)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 400)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } label: {
            Label(title, systemImage: "globe")
        }
    }
}

// MARK: - Previews

#Preview("Idle — markdown body") {
    WebFetchBlock(
        title: "Fetched https://example.com",
        url: "https://example.com/docs",
        httpStatus: 200,
        result: """
        # Example Docs

        This is **example** content fetched from the web. It includes:

        - Bulleted list
        - With [links](https://example.com)
        - And `inline code`

        ```swift
        let x = 42
        ```
        """,
        status: .idle
    )
    .padding()
    .frame(width: 600, height: 480, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Running") {
    WebFetchBlock(
        title: "Fetched https://example.com",
        url: "https://api.example.com/slow-endpoint",
        httpStatus: nil,
        result: nil,
        status: .running
    )
    .padding()
    .frame(width: 600, height: 320, alignment: .topLeading)
}

#Preview("Error — 404") {
    WebFetchBlock(
        title: "Fetched https://example.com",
        url: "https://example.com/not-found",
        httpStatus: 404,
        result: nil,
        status: .error("HTTP 404 Not Found")
    )
    .padding()
    .frame(width: 600, height: 320, alignment: .topLeading)
}
