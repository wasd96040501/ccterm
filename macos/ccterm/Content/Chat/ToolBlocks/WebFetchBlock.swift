import SwiftUI

/// Tool block for the `WebFetch` tool — header shows URL + HTTP status; body
/// renders the fetched content as markdown.
struct WebFetchBlock: View {
    let url: String
    let httpStatus: Int?
    let result: String?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(status: status, isExpanded: $isExpanded) {
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
            Label(labelText, systemImage: "globe")
        }
    }

    private var labelText: String {
        var out = url
        if let httpStatus { out += "  (\(httpStatus))" }
        return out
    }
}

// MARK: - Previews

#Preview("Idle — markdown body") {
    WebFetchBlock(
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
        url: "https://example.com/not-found",
        httpStatus: 404,
        result: nil,
        status: .error("HTTP 404 Not Found")
    )
    .padding()
    .frame(width: 600, height: 320, alignment: .topLeading)
}
