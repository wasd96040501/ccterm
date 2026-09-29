import AppKit

/// What Claude asked the reader and what they chose, kept together like a
/// form that was filled in; live, the options are controls and **Submit**
/// answers (07-talk.md "AskUserQuestion").
///
/// The tile heads the first question; each question is its header (13-pt
/// secondary), the question (14-pt label) and its options — chosen ones with
/// a filled mark in label colour, the others hollow and tertiary — 12 pt
/// apart. While it waits the options are radio buttons or checkboxes and
/// **Submit** (⌘↩) sits under them.
///
/// Laid out by hand from `Plan`, the one formula `height(for:width:)` also
/// answers with: the row is exactly as tall as what it lays out.
@MainActor
final class QuestionRowView: NSView, PageRowView {
    typealias Model = Question

    weak var delegate: PageRowViewDelegate?

    /// `ToolTileView`'s side, which a row is at least as tall as.
    private static let tileSide: CGFloat = 16
    private static let tileColumn: CGFloat = 24
    private static let headerHeight: CGFloat = 16
    private static let headerGap: CGFloat = 2
    private static let textGap: CGFloat = 6
    private static let optionHeight: CGFloat = 22
    private static let optionGap: CGFloat = 6
    private static let markColumn: CGFloat = 22
    private static let itemGap: CGFloat = 12
    private static let submitGap: CGFloat = 8
    private static let submitHeight: CGFloat = 22

    private static let headerFont = NSFont.systemFont(ofSize: 13)
    private static let textFont = NSFont.systemFont(ofSize: 14)
    private static let optionFont = NSFont.systemFont(ofSize: 13)
    private static let detailFont = NSFont.systemFont(ofSize: 12)

    /// Where everything goes at one width — measured from the model alone.
    private struct Plan {
        struct Item {
            var top: CGFloat
            var headerTop: CGFloat?
            var textTop: CGFloat
            var textHeight: CGFloat
            var optionsTop: CGFloat
            var height: CGFloat
        }

        var items: [Item]
        var submitTop: CGFloat?
        var height: CGFloat

        init(_ model: Question, width: CGFloat) {
            let available = max(0, width - QuestionRowView.tileColumn)
            var y: CGFloat = 0
            items = []
            for (index, item) in model.items.enumerated() {
                if index > 0 { y += QuestionRowView.itemGap }
                var laid = Item(
                    top: y, headerTop: nil, textTop: y, textHeight: 0, optionsTop: y, height: 0)
                var cursor = y
                if !item.header.isEmpty {
                    laid.headerTop = cursor
                    cursor += QuestionRowView.headerHeight + QuestionRowView.headerGap
                }
                laid.textTop = cursor
                laid.textHeight = QuestionRowView.wrappedHeight(
                    item.text, font: QuestionRowView.textFont, width: available)
                cursor += laid.textHeight
                if !item.options.isEmpty { cursor += QuestionRowView.textGap }
                laid.optionsTop = cursor
                cursor += QuestionRowView.optionHeight * CGFloat(item.options.count)
                laid.height = cursor - y
                items.append(laid)
                y = cursor
            }
            if model.isWaiting {
                y += QuestionRowView.submitGap
                submitTop = y
                y += QuestionRowView.submitHeight
            } else {
                submitTop = nil
            }
            height = max(y, QuestionRowView.tileSide)
        }
    }

    /// A question's options: their own superview, so radio buttons group by
    /// question, and top-down like the row.
    private final class OptionsView: NSView {
        override var isFlipped: Bool { true }
    }

    private struct OptionViews {
        /// Live: a radio button or checkbox with the label as its title.
        var button: NSButton?
        /// Answered: the mark.
        var mark: NSImageView?
        var label: NSTextField?
        var detail: NSTextField
    }

    private struct ItemViews {
        var header: NSTextField?
        var text: NSTextField
        /// Radio buttons group by their superview, so each question has its own.
        var options: NSView
        var optionViews: [OptionViews]
    }

    private let tileView = ToolTileView()
    private var itemViews: [ItemViews] = []
    private lazy var submit: NSButton = {
        let button = PillButton(title: String(localized: "Submit"), keys: "⌘↩", isPrimary: true)
        button.target = self
        button.action = #selector(submitPressed(_:))
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = .command
        return button
    }()
    private var model: Question?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(tileView)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    static func height(for model: Question, width: CGFloat) -> CGFloat {
        Plan(model, width: width).height
    }

    /// The height `text` wraps to at `width` — measured by the cell the label
    /// draws with, so measuring and drawing cannot disagree.
    private static func wrappedHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height)
    }

    func configure(with model: Question) {
        tileView.tile = model.tile
        // Answers ticked so far belong to this row's model; the same model
        // again keeps them.
        guard model != self.model else { return }
        self.model = model
        rebuild(model)
    }

    private func rebuild(_ model: Question) {
        for views in itemViews {
            views.header?.removeFromSuperview()
            views.text.removeFromSuperview()
            views.options.removeFromSuperview()
        }
        submit.removeFromSuperview()
        itemViews = model.items.map { item in
            let header =
                item.header.isEmpty ? nil : label(item.header, font: Self.headerFont, color: .secondaryLabelColor)
            let text = label(item.text, font: Self.textFont, color: .labelColor)
            text.maximumNumberOfLines = 0
            text.lineBreakMode = .byWordWrapping
            text.cell?.wraps = true
            let container = OptionsView()
            let optionViews = item.options.map { option in
                makeOption(option, of: item, waiting: model.isWaiting, in: container)
            }
            for view in [header, text, container].compactMap({ $0 }) { addSubview(view) }
            return ItemViews(header: header, text: text, options: container, optionViews: optionViews)
        }
        if model.isWaiting {
            addSubview(submit)
            updateSubmit()
        }
        needsLayout = true
    }

    private func makeOption(
        _ option: Question.Item.Option, of item: Question.Item, waiting: Bool, in container: NSView
    ) -> OptionViews {
        let detail = label(option.detail, font: Self.detailFont, color: .tertiaryLabelColor)
        detail.isHidden = option.detail.isEmpty
        container.addSubview(detail)
        if waiting {
            let button =
                item.allowsSeveral
                ? NSButton(checkboxWithTitle: option.label, target: self, action: #selector(optionPressed(_:)))
                : NSButton(radioButtonWithTitle: option.label, target: self, action: #selector(optionPressed(_:)))
            button.font = Self.optionFont
            button.lineBreakMode = .byTruncatingTail
            container.addSubview(button)
            return OptionViews(button: button, mark: nil, label: nil, detail: detail)
        }
        let mark = NSImageView()
        let symbol =
            item.allowsSeveral
            ? (option.isChosen ? "checkmark.square.fill" : "square")
            : (option.isChosen ? "circle.inset.filled" : "circle")
        mark.image = .symbol(symbol, pointSize: 11)
        mark.contentTintColor = option.isChosen ? .controlAccentColor : .tertiaryLabelColor
        let text = label(
            option.label, font: Self.optionFont, color: option.isChosen ? .labelColor : .tertiaryLabelColor)
        text.lineBreakMode = .byTruncatingTail
        container.addSubview(mark)
        container.addSubview(text)
        return OptionViews(button: nil, mark: mark, label: text, detail: detail)
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        let plan = Plan(model, width: bounds.width)
        let x = Self.tileColumn
        let available = max(0, bounds.width - x)
        tileView.frame = NSRect(x: 0, y: 0, width: QuestionRowView.tileSide, height: QuestionRowView.tileSide)
        for (views, laid) in zip(itemViews, plan.items) {
            if let header = views.header, let top = laid.headerTop {
                header.frame = NSRect(x: x, y: top, width: available, height: Self.headerHeight)
            }
            views.text.frame = NSRect(x: x, y: laid.textTop, width: available, height: laid.textHeight)
            views.options.frame = NSRect(
                x: x, y: laid.optionsTop, width: available,
                height: Self.optionHeight * CGFloat(views.optionViews.count))
            for (index, option) in views.optionViews.enumerated() {
                layoutOption(option, row: index, width: available)
            }
        }
        if let top = plan.submitTop {
            let size = submit.fittingSize
            submit.frame = NSRect(
                x: x, y: top + (Self.submitHeight - size.height) / 2, width: size.width, height: size.height)
        }
    }

    private func layoutOption(_ option: OptionViews, row: Int, width: CGFloat) {
        let top = CGFloat(row) * Self.optionHeight
        func centered(_ view: NSView, x: CGFloat, width: CGFloat) {
            let height = min(view.fittingSize.height, Self.optionHeight)
            view.frame = NSRect(x: x, y: top + (Self.optionHeight - height) / 2, width: width, height: height)
        }
        var labelEnd: CGFloat
        if let button = option.button {
            let natural = button.fittingSize.width
            let space = max(0, width - Self.optionGap)
            let buttonWidth = min(natural, space)
            centered(button, x: 0, width: buttonWidth)
            labelEnd = buttonWidth
        } else if let mark = option.mark, let label = option.label {
            centered(mark, x: 0, width: 16)
            let natural = label.fittingSize.width
            let labelWidth = min(natural, max(0, width - Self.markColumn - Self.optionGap))
            centered(label, x: Self.markColumn, width: labelWidth)
            labelEnd = Self.markColumn + labelWidth
        } else {
            return
        }
        labelEnd += Self.optionGap
        centered(option.detail, x: labelEnd, width: max(0, width - labelEnd))
    }

    // MARK: - Answering

    @objc private func optionPressed(_ sender: NSButton) {
        updateSubmit()
    }

    /// Submit answers once every question has an answer.
    private func updateSubmit() {
        submit.isEnabled = itemViews.allSatisfy { views in
            views.optionViews.contains { $0.button?.state == .on }
        }
    }

    @objc private func submitPressed(_ sender: NSButton) {
        guard let model else { return }
        var answers: [String: String] = [:]
        for (item, views) in zip(model.items, itemViews) {
            let chosen = zip(item.options, views.optionViews).filter { $1.button?.state == .on }.map(\.0.label)
            answers[item.text] = chosen.joined(separator: ", ")
        }
        delegate?.rowView(self, decide: .answer(answers), for: model.id)
    }

    /// The table takes focus, so ↑ / ↓ stay with the transcript.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}
