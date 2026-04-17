import SwiftUI

/// v1 placeholder for ``MarkdownSegment/table(_:)`` using SwiftUI `Grid`.
/// Cell contents are rendered via the shared attributed builder so inline
/// styles (code, emphasis, links) work inside cells.
struct MarkdownTableView: View {
    let table: MarkdownTable

    @Environment(\.markdownTheme) private var theme

    private var columnCount: Int {
        max(table.header.count, table.rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    cell(inlines: col < table.header.count ? table.header[col] : [],
                         isHeader: true,
                         column: col)
                }
            }
            .background(Color(nsColor: theme.tableHeaderBackground))

            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        cell(inlines: col < row.count ? row[col] : [],
                             isHeader: false,
                             column: col)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: theme.tableBorderColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func cell(inlines: [MarkdownInline], isHeader: Bool, column: Int) -> some View {
        let builder = MarkdownAttributedBuilder(theme: theme)
        let ns = builder.buildInline(inlines, bold: isHeader)
        let attr = (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(ns.string)
        Text(attr)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: alignment(for: column))
    }

    private func alignment(for column: Int) -> Alignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }
}
