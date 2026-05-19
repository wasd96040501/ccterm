#if DEBUG

import AgentSDK
import SwiftUI

/// Debug-only design preview surface — every `PermissionCardKind`
/// gets mounted into a real `NSWindow` so hover / focus / floating
/// chrome behave like production (SwiftUI's `#Preview` canvas has
/// been unreliable for this surface).
///
/// **Layout**: fixed-width columns, intrinsic-height cells —
/// a Pinterest-style masonry. Items declared in `Self.items` are
/// round-robin assigned to `columnCount` columns; each column is a
/// `VStack` so cards stack along their natural height with no
/// `ScrollView`. Width per column is locked; height flows.
///
/// **Adding a fixture**: append one entry to `Self.items`. The
/// next entry lands in the shortest column slot by index — no
/// further wiring needed.
struct PermissionCardsDemoView: View {

    // MARK: - Geometry (only width is fixed)

    private static let columnWidth: CGFloat = 480
    /// Two columns — three demo items currently land as
    /// [item0, item2] in column 0 and [item1] in column 1, so the
    /// third card no longer falls off the right edge.
    private static let columnCount: Int = 2
    private static let columnSpacing: CGFloat = 20
    private static let rowSpacing: CGFloat = 20
    private static let pagePadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ForEach(0..<Self.columnCount, id: \.self) { col in
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(Self.itemsInColumn(col)) { item in
                            cell(item: item)
                        }
                    }
                    .frame(width: Self.columnWidth, alignment: .top)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(Self.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Cell

    @ViewBuilder
    private func cell(item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            PermissionCardView(
                request: item.request,
                onAllowOnce: {},
                onAllowAlways: {},
                onDeny: {},
                onAllowWithInput: { _ in }
            )
            // Width locked to the column; no height frame so the
            // card sizes to its intrinsic content. Masonry flow
            // works precisely because the height is allowed to
            // breathe per cell.
            .frame(width: Self.columnWidth, alignment: .top)
        }
        .frame(width: Self.columnWidth, alignment: .leading)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Permission cards · masonry preview")
                .font(.system(size: 16, weight: .semibold))
            Text(
                "Fixed \(Int(Self.columnWidth))pt columns × \(Self.columnCount). "
                    + "Cell height flows from content — no ScrollView."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Items

    /// One cell in the masonry. Identified by `id` so SwiftUI keeps
    /// stable identity across column reshuffles.
    private struct Item: Identifiable {
        let id: String
        let title: String
        let request: PermissionRequest
    }

    /// Round-robin assignment of `items` into `columnCount`
    /// columns. Append-only growth lands the next item into the
    /// column with the fewest cells, which approximates a real
    /// masonry without measuring view heights.
    private static func itemsInColumn(_ index: Int) -> [Item] {
        items.enumerated()
            .filter { $0.offset % columnCount == index }
            .map { $0.element }
    }

    /// Declared fixtures. Append here to extend the demo.
    private static let items: [Item] = [
        Item(
            id: "ask-single",
            title: "AskUserQuestion · single-select",
            request: PermissionRequest.makePreview(
                requestId: "demo-ask-single",
                toolName: "AskUserQuestion",
                input: [
                    "questions": [
                        [
                            "question":
                                "Should we keep backwards-compatibility shims for the old API?",
                            "header": "Compat",
                            "multiSelect": false,
                            "options": [
                                [
                                    "label": "Yes, keep them",
                                    "description": "Existing clients still depend on them",
                                ],
                                [
                                    "label": "No, remove them",
                                    "description": "Cleaner break, faster releases",
                                ],
                                [
                                    "label": "Defer to next milestone",
                                    "description": "Re-evaluate after the migration",
                                ],
                            ],
                        ]
                    ]
                ])
        ),
        Item(
            id: "ask-multi",
            title: "AskUserQuestion · multi-select",
            request: PermissionRequest.makePreview(
                requestId: "demo-ask-multi",
                toolName: "AskUserQuestion",
                input: [
                    "questions": [
                        [
                            "question": "Which features should we enable in v1?",
                            "header": "Features",
                            "multiSelect": true,
                            "options": [
                                [
                                    "label": "Diff view",
                                    "description": "Side-by-side patches",
                                ],
                                ["label": "Inline syntax highlight"],
                                ["label": "Code folding"],
                                ["label": "Minimap"],
                            ],
                        ]
                    ]
                ])
        ),
        Item(
            id: "ask-multi-question",
            title: "AskUserQuestion · 3 questions in a row",
            request: PermissionRequest.makePreview(
                requestId: "demo-ask-multi-q",
                toolName: "AskUserQuestion",
                input: [
                    "questions": [
                        [
                            "question": "Pick the default theme.",
                            "header": "Theme",
                            "multiSelect": false,
                            "options": [
                                ["label": "Auto"],
                                ["label": "Light"],
                                ["label": "Dark"],
                            ],
                        ],
                        [
                            "question":
                                "Which timezone should the daily report default to?",
                            "header": "Timezone",
                            "options": [
                                ["label": "UTC"],
                                ["label": "America/Los_Angeles"],
                                ["label": "Asia/Shanghai"],
                            ],
                        ],
                        [
                            "question": "Do we ship a migration script in this PR?",
                            "header": "Migration",
                            "options": [
                                ["label": "Yes — include it"],
                                ["label": "No — handle ad hoc"],
                            ],
                        ],
                    ]
                ])
        ),
    ]
}

#endif
