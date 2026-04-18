import SwiftUI

/// Tool block for the `WebSearch` tool — header shows the query; body lists
/// search result entries (title + URL + optional snippet).
struct WebSearchBlock: View {
    let query: String
    let results: [SearchResult]
    let status: ToolBlockStatus

    @State private var isExpanded = false

    struct SearchResult: Identifiable {
        let id = UUID()
        let title: String
        let url: String
        let snippet: String?
    }

    var body: some View {
        ToolBlock(status: status, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(results) { result in
                    ResultRow(result: result)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Label("\"\(query)\"", systemImage: "text.magnifyingglass")
        }
    }
}

// MARK: - Subviews

private struct ResultRow: View {
    let result: WebSearchBlock.SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Text(result.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let snippet = result.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("Idle") {
    WebSearchBlock(
        query: "swiftui disclosure group custom style",
        results: [
            .init(
                title: "DisclosureGroup | Apple Developer Documentation",
                url: "https://developer.apple.com/documentation/swiftui/disclosuregroup",
                snippet: "A view that shows or hides another content view, based on the state of a disclosure control."),
            .init(
                title: "Styling SwiftUI DisclosureGroups",
                url: "https://swiftbysundell.com/articles/disclosure-group",
                snippet: "How to fully customize the chevron, label, and content of a DisclosureGroup on macOS."),
        ],
        status: .idle
    )
    .padding()
    .frame(width: 600, height: 300)
}

#Preview("Running") {
    WebSearchBlock(
        query: "how to build swift ui app on macos",
        results: [],
        status: .running
    )
    .padding()
    .frame(width: 600, height: 300)
}

#Preview("Error") {
    WebSearchBlock(
        query: "some query",
        results: [],
        status: .error("rate limit exceeded")
    )
    .padding()
    .frame(width: 600, height: 300)
}
