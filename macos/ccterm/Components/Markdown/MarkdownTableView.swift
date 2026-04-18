import SwiftUI

/// Renders a parsed Markdown table via SwiftUI `Grid`. All cell contents are
/// pre-built into `AttributedString`s during ``MarkdownView`` `refresh()`, so
/// `body` is a pure data lookup with no per-evaluation work.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let prebuilt: MarkdownView.PrebuiltTable?

    @Environment(\.markdownTheme) private var theme

    var body: some View {
        if let prebuilt {
            grid(prebuilt: prebuilt)
        } else {
            // Reached only when prebuilt construction was skipped (e.g. theme
            // change races refresh). Render nothing — refresh will re-fire.
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder
    private func grid(prebuilt: MarkdownView.PrebuiltTable) -> some View {
        let columnCount = prebuilt.columnCount
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    cell(text: prebuilt.header[col], column: col)
                }
            }
            .background(Color(nsColor: theme.tableHeaderBackground))

            // Header / body separator — uses the outer border color so it
            // reads as the strongest line in the grid.
            divider(color: theme.tableBorderColor)

            ForEach(Array(prebuilt.rows.enumerated()), id: \.offset) { idx, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        cell(text: row[col], column: col)
                    }
                }
                .background(idx.isMultiple(of: 2)
                    ? Color.clear
                    : Color(nsColor: theme.tableZebraBackground))

                if idx < prebuilt.rows.count - 1 {
                    divider(color: theme.tableInnerDividerColor)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: theme.tableBorderColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Hairline 1pt rule used between header and body, and between body rows.
    /// `Divider()` always uses `.separatorColor`; we want a configurable color.
    @ViewBuilder
    private func divider(color: NSColor) -> some View {
        Rectangle()
            .fill(Color(nsColor: color))
            .frame(height: 1)
    }

    @ViewBuilder
    private func cell(text: AttributedString, column: Int) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, theme.blockPadding)
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
