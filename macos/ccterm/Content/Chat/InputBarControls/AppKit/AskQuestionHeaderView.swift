import AppKit

/// The AskUserQuestion wizard's question header (migration plan §4.5). AppKit
/// replacement for the SwiftUI `questionHeader`
/// (`PermissionAskUserQuestionCardBody.swift:128-180`).
///
/// Two-row stack: an optional chip row (back chevron + "N / M" progress chip +
/// header chip) on top, then the question text on its own line below
/// (`:132`). The chip row is omitted entirely when none of the three chips are
/// present (`:130-131`), so a bare single-question payload doesn't leave a blank
/// band.
///
/// The back chevron is a self-drawn `NSControl`; it appears OPACITY-ONLY per D5
/// (the SwiftUI `.transition(.opacity.combined(with: .move))` drops the `.move`).
/// The question text is a selectable `NSTextField` (`.textSelection(.enabled)`,
/// §4.5-7).
@MainActor
final class AskQuestionHeaderView: NSView {

    var onBack: (() -> Void)?

    private let outerStack = NSStackView()
    private let chipRow = NSStackView()
    private let chevron: ChevronButton
    private let progressChip = ChipLabel(kind: .progress)
    private let headerChip = ChipLabel(kind: .header)
    private let questionField = NSTextField(wrappingLabelWithString: "")

    /// - Parameters:
    ///   - questionText: the in-flight question text.
    ///   - headerText: the optional header chip text.
    ///   - index: zero-based current index.
    ///   - total: total question count.
    init(questionText: String, headerText: String?, index: Int, total: Int) {
        chevron = ChevronButton()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let hasBack = index > 0
        let hasProgress = total > 1
        let hasHeader = (headerText?.isEmpty == false)
        let hasChipRow = hasBack || hasProgress || hasHeader  // `:130-131`

        // Chip row.
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = AskUserQuestionLayout.chipRowSpacing  // `:134`
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        chevron.onClick = { [weak self] in self?.onBack?() }
        chevron.isHidden = !hasBack
        chipRow.addArrangedSubview(chevron)

        progressChip.text = "\(index + 1) / \(total)"
        progressChip.isHidden = !hasProgress
        chipRow.addArrangedSubview(progressChip)

        if let headerText, hasHeader {
            headerChip.text = headerText
            chipRow.addArrangedSubview(headerChip)
        }

        let chipSpacer = NSView()
        chipSpacer.translatesAutoresizingMaskIntoConstraints = false
        chipSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chipRow.addArrangedSubview(chipSpacer)

        // Question text — selectable, wrapping, leading (`:173-178`).
        questionField.stringValue = questionText
        questionField.font = .systemFont(
            ofSize: AskUserQuestionLayout.questionTextSize, weight: .semibold)
        questionField.textColor = .labelColor
        questionField.isSelectable = true
        questionField.isEditable = false
        questionField.isBordered = false
        questionField.drawsBackground = false
        questionField.maximumNumberOfLines = 0
        questionField.translatesAutoresizingMaskIntoConstraints = false
        questionField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        questionField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Outer vertical stack.
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = AskUserQuestionLayout.headerInnerSpacing  // `:132`
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        if hasChipRow { outerStack.addArrangedSubview(chipRow) }
        outerStack.addArrangedSubview(questionField)

        addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if hasChipRow {
            chipRow.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor).isActive = true
            chipRow.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor).isActive = true
        }
        questionField.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor).isActive = true
        questionField.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    var isBackVisible: Bool { !chevron.isHidden }
    var isProgressVisible: Bool { !progressChip.isHidden }
    var progressText: String { progressChip.text }
    var questionText: String { questionField.stringValue }

    // MARK: - Back chevron (self-drawn, opacity-only per D5)

    /// A borderless chevron-left control, 18×18 (`:137-144`).
    private final class ChevronButton: NSControl {
        var onClick: (() -> Void)?
        private let imageView = NSImageView()

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(
                systemSymbolName: "chevron.left", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: AskUserQuestionLayout.chevronSize, weight: .semibold))
            imageView.contentTintColor = .secondaryLabelColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageAlignment = .alignCenter
            addSubview(imageView)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: AskUserQuestionLayout.chevronFrame),
                heightAnchor.constraint(equalToConstant: AskUserQuestionLayout.chevronFrame),
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setContentHuggingPriority(.required, for: .horizontal)
            toolTip = String(localized: "Previous question")  // `:144` `.help`
            setAccessibilityRole(.button)
            setAccessibilityLabel(String(localized: "Previous question"))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        nonisolated deinit {}

        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?()
        }
    }

    // MARK: - Chip label (rounded background pill)

    /// A small rounded chip: secondary-tinted for progress, accent-tinted for
    /// the header (`:148-168`).
    private final class ChipLabel: NSView {
        enum Kind { case progress, header }
        private let kind: Kind
        private let field = NSTextField(labelWithString: "")
        private let fillLayer = CALayer()

        var text: String {
            get { field.stringValue }
            set { field.stringValue = newValue }
        }

        init(kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            fillLayer.cornerCurve = .continuous
            fillLayer.cornerRadius = AskUserQuestionLayout.chipCornerRadius
            layer?.addSublayer(fillLayer)

            field.font = .systemFont(
                ofSize: AskUserQuestionLayout.chipFontSize,
                weight: kind == .header ? .semibold : .medium)
            field.textColor = kind == .header ? .controlAccentColor : .secondaryLabelColor
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: AskUserQuestionLayout.chipHPadding),
                field.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -AskUserQuestionLayout.chipHPadding),
                field.topAnchor.constraint(
                    equalTo: topAnchor, constant: AskUserQuestionLayout.chipVPadding),
                field.bottomAnchor.constraint(
                    equalTo: bottomAnchor, constant: -AskUserQuestionLayout.chipVPadding),
            ])
            setContentHuggingPriority(.required, for: .horizontal)
            applyFill()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        nonisolated deinit {}

        override func layout() {
            super.layout()
            fillLayer.frame = bounds
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyFill()
            field.textColor = kind == .header ? .controlAccentColor : .secondaryLabelColor
        }

        /// progress chip fill `primary.opacity(0.06)` (`:156`); header chip fill
        /// `accentColor.opacity(0.12)` (`:167`).
        private func applyFill() {
            var color: CGColor =
                kind == .header
                ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
                : NSColor.labelColor.withAlphaComponent(0.06).cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                color =
                    self.kind == .header
                    ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
                    : NSColor.labelColor.withAlphaComponent(0.06).cgColor
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.backgroundColor = color
            CATransaction.commit()
        }
    }
}
