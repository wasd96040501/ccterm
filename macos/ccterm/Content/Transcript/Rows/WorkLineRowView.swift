import AppKit

/// One line of work: a run's row, one of its items, a row of news or one
/// piece of it (design/transcript/01-run.md, 04-background.md).
///
/// Tile, words, the exceptions set apart from them, trailing meta, and the
/// accessory that says what a click does — a chevron that expands, or, on
/// hover, `arrow.up.right` that opens beside. An item is indented one tile
/// and a gap, and a failed item adds its first error line under it.
@MainActor
final class WorkLineRowView: NSView, PageRowView {
    struct Model: Equatable {
        enum Level: Equatable {
            /// A run's or news's own row: 28 pt.
            case line
            /// One item under an expanded row: 24 pt, indented 24.
            case item
        }

        enum Action: Equatable {
            /// A click opens `id` beside (a double-click pins it).
            case open(String)
            /// A click expands or collapses run `id`; the chevron shows which.
            case toggle(String, expanded: Bool)
        }

        var line: WorkLine
        var level: Level
        var action: Action
        /// The call that started a background task: ↖ on hover reveals it.
        var origin: String?
        /// A failed item's first error line, in red under it.
        var error: String?
        /// Its document is the one showing beside: the selection highlight.
        var isSelected: Bool
        /// Just brought into view by *Show in Transcript* or ↖: flash once
        /// as configured, then settle to `isSelected`.
        var flashes: Bool
    }

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Model, width: CGFloat) -> CGFloat {
        switch model.level {
        case .line: 28
        case .item: model.error == nil ? 24 : 44
        }
    }

    func configure(with model: Model) {}
}
