import AppKit
import DisplayModels

/// What Claude asked the reader and what they chose, kept together like a
/// form that was filled in; live, the options are controls and **Submit**
/// answers (07-talk.md "AskUserQuestion").
///
/// The tile heads the first question; each question is its header (13-pt
/// secondary, *Choose any* after it when several may be picked), the question
/// (14-pt label) and its options, 12 pt apart. An option is two lines — its
/// label and, under it, its description, both wrapped and never cut — with the
/// mark on the label's line: chosen ones filled and in label colour, the others
/// hollow and tertiary. While it waits each option is a radio button or a
/// checkbox whose title is both lines — the control takes the click on its
/// mark and words, the keys and VoiceOver, and a question's radio buttons are
/// one group — the last option of each question is *Other* (a text field), an
/// option with a preview shows it beside the list with a *Notes* field, and
/// **Submit** (⌘↩, enabled once every question has an answer) and *Chat About
/// This* sit under them; ⎋ declines.
///
/// Laid out by hand from `Metrics`, the one formula `height(for:width:)` also
/// answers with: the row is exactly as tall as what it lays out, whatever is
/// picked — the preview's room is reserved.
@MainActor
public final class QuestionRowView: NSView, PageRowView {
    public typealias Model = Question

    public weak var delegate: PageRowViewDelegate?

    /// `TileView`'s side, which a row is at least as tall as.
    private static let tileSide: CGFloat = 16
    private static let tileColumn: CGFloat = 24
    private static let headerHeight: CGFloat = 16
    private static let headerGap: CGFloat = 2
    private static let textGap: CGFloat = 6
    /// An option's padding above and below its words (`.qa .opt` 4).
    private static let optionPad: CGFloat = 4
    /// The label's 18-pt lines and the description's 16 (`.qa .opt .l`, `.d`).
    private static let labelLine: CGFloat = 18
    private static let detailLine: CGFloat = 16
    private static let markColumn: CGFloat = 22
    private static let itemGap: CGFloat = 12
    private static let buttonsGap: CGFloat = 8
    private static let buttonsHeight: CGFloat = 22
    /// *Other*: an option whose one line is the field (4 + 18 + 4).
    private static let otherHeight: CGFloat = 26
    private static let previewHeight: CGFloat = 96
    private static let notesHeight: CGFloat = 24
    private static let previewGap: CGFloat = 8
    private static let columnGap: CGFloat = 16
    /// Wide enough to set a preview beside the options.
    private static let besideWidth: CGFloat = 480
    /// The note under an answered card (`.qa .qnote`: 4 under the question's
    /// own 6, 12-pt words on a 15-pt line).
    private static let outcomeGap: CGFloat = 4
    private static let outcomeHeight: CGFloat = 15

    private static let headerFont = NSFont.systemFont(ofSize: 13)
    private static let textFont = NSFont.systemFont(ofSize: 14)
    private static let optionFont = NSFont.systemFont(ofSize: 13)
    private static let detailFont = NSFont.systemFont(ofSize: 12)
    private static let previewFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // MARK: - Metrics

    /// Where everything goes at one width — measured from the model alone.
    private struct Metrics {
        struct Option {
            var top: CGFloat
            var labelHeight: CGFloat
            var detailHeight: CGFloat
            var height: CGFloat
        }

        struct Item {
            var headerTop: CGFloat?
            var textTop: CGFloat
            var textHeight: CGFloat
            var listTop: CGFloat
            var listWidth: CGFloat
            var options: [Option]
            /// The *Other* row, while waiting.
            var otherTop: CGFloat?
            var listHeight: CGFloat
            /// The preview and notes column, when the question has previews.
            var previewOrigin: CGPoint?
            var previewWidth: CGFloat
            var top: CGFloat
        }

        var items: [Item] = []
        var buttonsTop: CGFloat?
        var outcomeTop: CGFloat?
        var height: CGFloat = 0

        init(_ model: Question, width: CGFloat) {
            let available = max(0, width - QuestionRowView.tileColumn)
            var y: CGFloat = 0
            for (index, item) in model.items.enumerated() {
                if index > 0 { y += QuestionRowView.itemGap }
                var laid = Item(
                    headerTop: nil, textTop: y, textHeight: 0, listTop: y, listWidth: available, options: [],
                    otherTop: nil, listHeight: 0, previewOrigin: nil, previewWidth: 0, top: y)
                var cursor = y
                if !item.header.isEmpty || item.hint != nil {
                    laid.headerTop = cursor
                    cursor += QuestionRowView.headerHeight + QuestionRowView.headerGap
                }
                laid.textTop = cursor
                laid.textHeight = QuestionRowView.wrappedHeight(
                    item.text, font: QuestionRowView.textFont, width: available)
                cursor += laid.textHeight + QuestionRowView.textGap
                laid.listTop = cursor

                let previewing = model.isWaiting && item.hasPreviews
                let beside = previewing && available >= QuestionRowView.besideWidth
                laid.listWidth = beside ? (available * 0.55).rounded(.down) : available
                let inner = max(0, laid.listWidth - QuestionRowView.markColumn)
                var top: CGFloat = 0
                for option in model.isTalkedOver ? [] : item.options {
                    if model.isWaiting {
                        // Measured by the control that draws it.
                        let height = QuestionRowView.liveOptionHeight(
                            option, several: item.allowsSeveral, width: laid.listWidth)
                        laid.options.append(Option(top: top, labelHeight: 0, detailHeight: 0, height: height))
                        top += height
                        continue
                    }
                    let label = QuestionRowView.linedHeight(
                        option.label, font: QuestionRowView.optionFont, line: QuestionRowView.labelLine, width: inner)
                    let detail =
                        option.detail.isEmpty
                        ? 0
                        : QuestionRowView.linedHeight(
                            option.detail, font: QuestionRowView.detailFont, line: QuestionRowView.detailLine,
                            width: inner)
                    let height = 2 * QuestionRowView.optionPad + label + detail
                    laid.options.append(Option(top: top, labelHeight: label, detailHeight: detail, height: height))
                    top += height
                }
                if model.isWaiting {
                    laid.otherTop = top
                    top += QuestionRowView.otherHeight
                }
                laid.listHeight = top
                let previewColumn =
                    QuestionRowView.previewHeight + QuestionRowView.previewGap + QuestionRowView.notesHeight
                if previewing {
                    if beside {
                        laid.previewOrigin = CGPoint(
                            x: laid.listWidth + QuestionRowView.columnGap, y: laid.listTop)
                        laid.previewWidth = available - laid.listWidth - QuestionRowView.columnGap
                        cursor += max(top, previewColumn)
                    } else {
                        laid.previewOrigin = CGPoint(x: 0, y: laid.listTop + top + QuestionRowView.previewGap)
                        laid.previewWidth = available
                        cursor += top + QuestionRowView.previewGap + previewColumn
                    }
                } else {
                    cursor += top
                }
                items.append(laid)
                y = cursor
            }
            if model.isWaiting {
                y += QuestionRowView.buttonsGap
                buttonsTop = y
                y += QuestionRowView.buttonsHeight
            } else if model.outcome != nil {
                y += QuestionRowView.outcomeGap
                outcomeTop = y
                y += QuestionRowView.outcomeHeight
            }
            height = max(y, QuestionRowView.tileSide)
        }
    }

    // MARK: - Views

    /// An answered option: its mark, filled when chosen, its label and its
    /// description — words to read, not a control.
    private final class AnsweredOptionView: NSView {
        let mark = NSImageView()
        let label = NSTextField(wrappingLabelWithString: "")
        let detail = NSTextField(wrappingLabelWithString: "")

        init(_ option: Question.Item.Option, several: Bool) {
            super.init(frame: .zero)
            let symbol =
                several
                ? (option.isChosen ? "checkmark.square.fill" : "square")
                : (option.isChosen ? "circle.inset.filled" : "circle")
            mark.image = .symbol(symbol, pointSize: 12)
            mark.contentTintColor = option.isChosen ? .controlAccentColor : .tertiaryLabelColor
            mark.imageScaling = .scaleNone
            for text in [label, detail] {
                text.isSelectable = false
                text.maximumNumberOfLines = 0
                text.lineBreakMode = .byWordWrapping
            }
            label.attributedStringValue = QuestionRowView.lined(
                option.label, font: QuestionRowView.optionFont, line: QuestionRowView.labelLine,
                color: option.isChosen ? .labelColor : .tertiaryLabelColor)
            detail.attributedStringValue = QuestionRowView.lined(
                option.detail, font: QuestionRowView.detailFont, line: QuestionRowView.detailLine,
                color: option.isChosen ? .secondaryLabelColor : .tertiaryLabelColor)
            detail.isHidden = option.detail.isEmpty
            for view in [mark, label, detail] { addSubview(view) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }

        func layoutContent(_ metrics: Metrics.Option) {
            let inner = max(0, bounds.width - QuestionRowView.markColumn)
            let pad = QuestionRowView.optionPad
            // Centred on the label's first 18-pt line.
            mark.frame = NSRect(x: 0, y: pad + (QuestionRowView.labelLine - 16) / 2, width: 16, height: 16)
            label.frame = NSRect(x: QuestionRowView.markColumn, y: pad, width: inner, height: metrics.labelHeight)
            detail.frame = NSRect(
                x: QuestionRowView.markColumn, y: pad + metrics.labelHeight, width: inner,
                height: metrics.detailHeight)
        }
    }

    /// A waiting question's options: a radio button or checkbox per option,
    /// then *Other* — its button and the field it is typed in. The buttons
    /// share this view and one action, so a question's radio buttons are one
    /// group, apart from every other question's.
    private final class OptionList: NSView {
        let buttons: [NSButton]
        let field = NSTextField()

        /// The *Other* row's button, last of `buttons`.
        var other: NSButton { buttons[buttons.count - 1] }

        init(_ item: Question.Item, target: AnyObject, action: Selector) {
            let titles = item.options.map(QuestionRowView.liveTitle) + [NSAttributedString()]
            buttons = titles.map { title in
                let button =
                    item.allowsSeveral
                    ? NSButton(checkboxWithTitle: "", target: target, action: action)
                    : NSButton(radioButtonWithTitle: "", target: target, action: action)
                button.attributedTitle = title
                button.lineBreakMode = .byWordWrapping
                return button
            }
            super.init(frame: .zero)
            field.placeholderAttributedString = NSAttributedString(
                string: item.otherLabel,
                attributes: [.font: QuestionRowView.optionFont, .foregroundColor: NSColor.tertiaryLabelColor])
            field.font = QuestionRowView.optionFont
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.lineBreakMode = .byTruncatingTail
            other.setAccessibilityLabel(item.otherLabel)
            for view in buttons + [field] { addSubview(view) }
            setAccessibilityElement(true)
            setAccessibilityRole(item.allowsSeveral ? .group : .radioGroup)
            setAccessibilityLabel(item.text)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }

        /// Each option's row, top to bottom, *Other*'s last: an option's
        /// button fills its row; *Other*'s mark takes the row's start and the
        /// field the rest of its one line.
        func place(_ rows: [NSRect]) {
            for (button, row) in zip(buttons.dropLast(), rows) { button.frame = row }
            guard let row = rows.last else { return }
            other.frame = NSRect(x: row.minX, y: row.minY, width: QuestionRowView.markColumn, height: row.height)
            // A borderless field sets its words 2 in from its edge: back by
            // as much, they start where the options' labels do.
            let fieldX = QuestionRowView.markColumn - 2
            field.frame = NSRect(
                x: fieldX, y: row.midY - QuestionRowView.labelLine / 2, width: max(0, row.width - fieldX),
                height: QuestionRowView.labelLine)
        }
    }

    private struct ItemViews {
        var header: NSTextField?
        var text: NSTextField
        /// Answered: the options to read.
        var answered: [AnsweredOptionView]
        /// Waiting: the options to choose.
        var list: OptionList?
        var previewBox: NSView?
        var preview: NSTextField?
        var notes: NSTextField?
    }

    private let tileView = TileView()
    private var itemViews: [ItemViews] = []
    private let outcome = NSTextField(labelWithString: "")
    private lazy var submit: NSButton = {
        let button = PillButton(title: String(localized: "Submit", bundle: .module), keys: "⌘↩", isPrimary: true)
        button.target = self
        button.action = #selector(submitPressed(_:))
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = .command
        return button
    }()
    private lazy var chat: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: String(localized: "Chat About This", bundle: .module),
            attributes: [.font: Self.optionFont, .foregroundColor: NSColor.secondaryLabelColor])
        button.target = self
        button.action = #selector(chatPressed(_:))
        return button
    }()
    private var model: Question?

    /// Per question, what the reader typed in *Other* and their notes. What
    /// they picked is the buttons' state (`picked(_:)`).
    private var typed: [String] = []
    private var notes: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(tileView)
        outcome.font = .systemFont(ofSize: 12)
        outcome.textColor = .tertiaryLabelColor
        addSubview(outcome)
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var isFlipped: Bool { true }

    public override var acceptsFirstResponder: Bool { model?.isWaiting == true }

    public static func height(for model: Question, width: CGFloat) -> CGFloat {
        Metrics(model, width: width).height
    }

    /// `text` on fixed `line`-high lines, its words centred in each (the
    /// sheet's line-height), as an option's label and description are set.
    static func lined(_ text: String, font: NSFont, line: CGFloat, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        style.lineBreakMode = .byWordWrapping
        // AppKit puts a fixed line's extra room above the words; half of it goes back under.
        let natural = font.ascender - font.descender + font.leading
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style, .baselineOffset: (line - natural) / 2,
            ])
    }

    /// The height `text` takes on `line`-high lines at `width`, measured by the
    /// cell the label draws with.
    private static func linedHeight(_ text: String, font: NSFont, line: CGFloat, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: "")
        cell.attributedStringValue = lined(text, font: font, line: line, color: .labelColor)
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(width, 1), height: 100_000)).height
        return max(line, (height / line).rounded() * line)
    }

    /// A live option's title: its label on 18-pt lines and, under it, its
    /// description on 16.
    fileprivate static func liveTitle(_ option: Question.Item.Option) -> NSAttributedString {
        let title = NSMutableAttributedString(
            attributedString: lined(option.label, font: optionFont, line: labelLine, color: .labelColor))
        if !option.detail.isEmpty {
            title.append(
                lined("\n" + option.detail, font: detailFont, line: detailLine, color: .secondaryLabelColor))
        }
        return title
    }

    private static let radioCell = NSButton(radioButtonWithTitle: "", target: nil, action: nil).cell
    private static let checkboxCell = NSButton(checkboxWithTitle: "", target: nil, action: nil).cell

    /// A live option's height at `width`: its button's, measured by the
    /// button's own cell, and the option's padding above and below.
    private static func liveOptionHeight(_ option: Question.Item.Option, several: Bool, width: CGFloat) -> CGFloat {
        guard let cell = (several ? checkboxCell : radioCell) as? NSButtonCell else { return 0 }
        cell.attributedTitle = liveTitle(option)
        cell.lineBreakMode = .byWordWrapping
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(width, 1), height: 100_000))
        return 2 * optionPad + ceil(size.height)
    }

    /// The height `text` wraps to at `width` — measured by the cell the label
    /// draws with, so measuring and drawing cannot disagree.
    private static func wrappedHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(width, 1), height: 100_000)).height)
    }

    public func configure(with model: Question) {
        tileView.tile = model.tile
        // What is picked so far belongs to this row's model; the same model
        // again keeps it.
        guard model != self.model else { return }
        self.model = model
        rebuild(model)
    }

    private func rebuild(_ model: Question) {
        for views in itemViews {
            for view in [views.header, views.text, views.list, views.previewBox, views.notes] {
                view?.removeFromSuperview()
            }
            for option in views.answered { option.removeFromSuperview() }
        }
        submit.removeFromSuperview()
        chat.removeFromSuperview()
        typed = model.items.map { _ in "" }
        notes = model.items.map { _ in "" }
        outcome.stringValue = model.outcome ?? ""
        outcome.isHidden = model.outcome == nil || model.isWaiting

        itemViews = model.items.enumerated().map { index, item in
            let header = headerField(item)
            let text = label(item.text, font: Self.textFont, color: .labelColor)
            text.maximumNumberOfLines = 0
            text.lineBreakMode = .byWordWrapping
            let answered =
                model.isWaiting || model.isTalkedOver
                ? [] : item.options.map { AnsweredOptionView($0, several: item.allowsSeveral) }
            var list: OptionList?
            var box: NSView?
            var preview: NSTextField?
            var notesField: NSTextField?
            if model.isWaiting {
                let options = OptionList(item, target: self, action: #selector(optionPressed(_:)))
                options.field.delegate = self
                options.field.tag = index
                list = options
                if item.hasPreviews {
                    box = PreviewBox()
                    let words = NSTextField(wrappingLabelWithString: "")
                    words.font = Self.previewFont
                    words.textColor = .secondaryLabelColor
                    words.isSelectable = false
                    words.maximumNumberOfLines = 0
                    box?.addSubview(words)
                    preview = words
                    let field = NSTextField()
                    field.placeholderString = item.notesPlaceholder
                    field.font = .systemFont(ofSize: 12)
                    field.bezelStyle = .roundedBezel
                    field.delegate = self
                    field.tag = 1000 + index
                    notesField = field
                }
            }
            for view in [header, text, box, notesField, list].compactMap({ $0 }) { addSubview(view) }
            for option in answered { addSubview(option) }
            return ItemViews(
                header: header, text: text, answered: answered, list: list, previewBox: box, preview: preview,
                notes: notesField)
        }
        if model.isWaiting {
            addSubview(submit)
            addSubview(chat)
            update()
        }
        needsLayout = true
    }

    private func headerField(_ item: Question.Item) -> NSTextField? {
        guard !item.header.isEmpty || item.hint != nil else { return nil }
        let words = NSMutableAttributedString(
            string: item.header,
            attributes: [.font: Self.headerFont, .foregroundColor: NSColor.secondaryLabelColor])
        if let hint = item.hint {
            words.append(
                NSAttributedString(
                    string: (item.header.isEmpty ? "" : "  ") + hint,
                    attributes: [.font: Self.headerFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let field = NSTextField(labelWithAttributedString: words)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        return field
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        guard let model else { return }
        let plan = Metrics(model, width: bounds.width)
        let x = Self.tileColumn
        let available = max(0, bounds.width - x)
        tileView.frame = NSRect(x: 0, y: 0, width: Self.tileSide, height: Self.tileSide)
        for (views, laid) in zip(itemViews, plan.items) {
            if let header = views.header, let top = laid.headerTop {
                header.frame = NSRect(x: x, y: top, width: available, height: Self.headerHeight)
            }
            views.text.frame = NSRect(x: x, y: laid.textTop, width: available, height: laid.textHeight)
            for (option, metrics) in zip(views.answered, laid.options) {
                option.frame = NSRect(
                    x: x, y: laid.listTop + metrics.top, width: laid.listWidth, height: metrics.height)
                option.layoutContent(metrics)
            }
            if let list = views.list, let otherTop = laid.otherTop {
                list.frame = NSRect(x: x, y: laid.listTop, width: laid.listWidth, height: laid.listHeight)
                let rows =
                    laid.options.map { NSRect(x: 0, y: $0.top, width: laid.listWidth, height: $0.height) }
                    + [NSRect(x: 0, y: otherTop, width: laid.listWidth, height: Self.otherHeight)]
                list.place(rows)
            }
            if let origin = laid.previewOrigin, let box = views.previewBox, let notes = views.notes {
                box.frame = NSRect(
                    x: x + origin.x, y: origin.y, width: laid.previewWidth, height: Self.previewHeight)
                views.preview?.frame = box.bounds.insetBy(dx: 8, dy: 6)
                notes.frame = NSRect(
                    x: x + origin.x, y: origin.y + Self.previewHeight + Self.previewGap, width: laid.previewWidth,
                    height: Self.notesHeight)
            }
        }
        if let top = plan.buttonsTop {
            let size = submit.fittingSize
            submit.frame = NSRect(
                x: x, y: top + (Self.buttonsHeight - size.height) / 2, width: size.width, height: size.height)
            // `.btn.plain`: a pill without its fill, 8 after Submit, its words 14 in.
            let chatSize = chat.fittingSize
            chat.frame = NSRect(
                x: submit.frame.maxX + 8, y: top + (Self.buttonsHeight - chatSize.height) / 2,
                width: ceil(chat.attributedTitle.size().width) + 2 * 14, height: chatSize.height)
        }
        if let top = plan.outcomeTop {
            outcome.frame = NSRect(x: x, y: top, width: available, height: Self.outcomeHeight)
        }
    }

    // MARK: - Answering

    /// What question `index` has picked: the options whose buttons are on,
    /// *Other* one past the last.
    private func picked(_ index: Int) -> Set<Int> {
        guard let list = itemViews[index].list else { return [] }
        return Set(list.buttons.indices.filter { list.buttons[$0].state == .on })
    }

    /// A button was pressed — clicked, or Space while it has the keys. The
    /// button has already changed its state (and a radio button its group's);
    /// *Other* takes the keyboard to its field.
    @objc private func optionPressed(_ sender: NSButton) {
        guard let list = sender.superview as? OptionList else { return }
        if sender === list.other, sender.state == .on {
            window?.makeFirstResponder(list.field)
        } else if !((window?.firstResponder as? NSView)?.isDescendant(of: self) ?? false) {
            // ⎋ declines while the card has the keys.
            window?.makeFirstResponder(self)
        }
        update()
    }

    /// The preview and whether Submit can answer.
    private func update() {
        guard let model, model.isWaiting else { return }
        for (index, item) in model.items.enumerated() {
            let views = itemViews[index]
            if item.hasPreviews {
                let shown = picked(index).first.flatMap {
                    item.options.indices.contains($0) ? item.options[$0].preview : nil
                }
                views.preview?.stringValue = shown ?? ""
                views.previewBox?.isHidden = shown == nil
                views.notes?.isHidden = shown == nil
            }
        }
        submit.isEnabled = model.items.indices.allSatisfy(isAnswered)
    }

    private func isAnswered(_ index: Int) -> Bool {
        guard let model else { return false }
        let other = model.items[index].options.count
        let typedWords = typed[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return picked(index).contains { $0 != other || !typedWords.isEmpty }
    }

    /// The answer of question `index` so far: the chosen labels, several
    /// joined by `", "`, and what was typed in *Other*.
    private func answer(_ index: Int) -> String? {
        guard let model else { return nil }
        let item = model.items[index]
        var parts = picked(index).sorted().compactMap { position -> String? in
            if position < item.options.count { return item.options[position].label }
            let words = typed[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
        if !item.allowsSeveral { parts = Array(parts.prefix(1)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @objc private func submitPressed(_ sender: NSButton) {
        guard let model, submit.isEnabled else { return }
        var answers: [String: String] = [:]
        var written: [String: String] = [:]
        for (index, item) in model.items.enumerated() {
            answers[item.text] = answer(index)
            let words = notes[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPreviews, !words.isEmpty { written[item.text] = words }
        }
        delegate?.pageRowView(self, didDecide: .answer(answers, notes: written), forCall: model.id)
    }

    /// *Chat About This*: nothing is answered, and what was picked and noted goes along.
    @objc private func chatPressed(_ sender: NSButton) {
        guard let model else { return }
        var answers: [String: String] = [:]
        var written: [String: String] = [:]
        for (index, item) in model.items.enumerated() {
            if let given = answer(index) { answers[item.text] = given }
            let words = notes[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPreviews, !words.isEmpty { written[item.text] = words }
        }
        delegate?.pageRowView(self, didDecide: .chatAbout(answers: answers, notes: written), forCall: model.id)
    }

    /// ⎋ declines the question.
    public override func cancelOperation(_ sender: Any?) {
        guard let model, model.isWaiting else { return super.cancelOperation(sender) }
        delegate?.pageRowView(self, didDecide: .deny, forCall: model.id)
    }

    /// Pressing the form takes focus for ⎋, and the table keeps ↑ / ↓.
    public override func mouseDown(with event: NSEvent) {
        if model?.isWaiting == true { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    /// The preview's panel: the inset wash a command's block has.
    private final class PreviewBox: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.cornerCurve = .continuous
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            }
        }
    }
}

extension QuestionRowView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let model else { return }
        if field.tag >= 1000 {
            let index = field.tag - 1000
            if notes.indices.contains(index) { notes[index] = field.stringValue }
            return
        }
        guard typed.indices.contains(field.tag), let list = itemViews[field.tag].list else { return }
        typed[field.tag] = field.stringValue
        // Typing chooses *Other*; emptying the field takes it back. A radio
        // group follows only a press, so its other buttons are turned off here.
        if field.stringValue.isEmpty {
            list.other.state = .off
        } else {
            if !model.items[field.tag].allowsSeveral {
                for button in list.buttons { button.state = .off }
            }
            list.other.state = .on
        }
        update()
    }
}

/// The question's fixed control copy: the view's, not the page's.
extension Question.Item {
    /// After the header of a multi-select question.
    fileprivate var hint: String? { allowsSeveral ? String(localized: "Choose any", bundle: .module) : nil }

    /// The row the reader types an answer in, always last while it waits.
    fileprivate var otherLabel: String { String(localized: "Other — type something", bundle: .module) }

    /// Under a previewed option, where the reader's words go back as *User notes*.
    fileprivate var notesPlaceholder: String { String(localized: "Notes", bundle: .module) }
}
