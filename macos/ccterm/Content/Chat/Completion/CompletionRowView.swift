import AppKit

/// AppKit replacement for `CompletionListView`'s `completionRow` /
/// `commandLine` (migration plan §4.3). One lean, flipped NSView per
/// completion item: a 24pt command line (optional file icon + optional source
/// badge + truncating display text) plus, WHEN SELECTED, a reserved 36pt
/// two-line in-row description block. The selected highlight
/// (`accentColor.opacity(0.2)`) covers BOTH lines, drawn from the row's own
/// `isSelected` flag (the popup writes it during `reconcile` — exactly one
/// writer per phase, §4.3-3).
///
/// Tap-to-confirm: `mouseUp` inside the row fires `onClick(index)` which the
/// controller routes to "set selectedIndex = index THEN confirm" (matching
/// the SwiftUI `onTapGesture { selectedIndex = index; onConfirm }`,
/// `CompletionListView.swift:145-148`).
final class CompletionRowView: NSView {

    /// Index of this row in `CompletionState.items`, reported on click.
    let index: Int
    /// Fired on `mouseUp` inside the row. The controller sets `selectedIndex`
    /// then confirms (§4.3 — set-then-confirm so confirm acts on this row).
    var onClick: ((Int) -> Void)?

    private let item: any CompletionItem
    private let isSelected: Bool

    private let commandLineView = NSView()
    private var iconView: NSImageView?
    private var badgeView: BadgeView?
    private let textField = NSTextField(labelWithString: "")
    private var detailField: NSTextField?

    /// Top-left origin so subviews lay out top-down inside the row, matching
    /// the SwiftUI VStack order (command line, then optional detail).
    override var isFlipped: Bool { true }

    /// `CompletionRowView` builds its content once at construction — the popup
    /// reconciles by rebuilding the row stack, never by mutating a live row,
    /// so the row's `(item, index, isSelected, isFirst, isLast)` are immutable.
    init(item: any CompletionItem, index: Int, isSelected: Bool, isFirst: Bool, isLast: Bool) {
        self.item = item
        self.index = index
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildCommandLine()
        buildDetailIfSelected()
        applyHighlight()
        // `.padding(.top, isFirst ? verticalInset : 0)` /
        // `.padding(.bottom, isLast ? verticalInset : 0)` are applied by the
        // popup as stack spacing/inset; the row itself carries no outer pad.
        _ = (isFirst, isLast)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - Command line (verbatim layout from CompletionListView.swift:154-185)

    private func buildCommandLine() {
        commandLineView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandLineView)

        let hasIcon = item.displayIcon != nil
        let hasBadge = (item.displayBadge?.isEmpty == false)

        var leadingAnchorView: NSLayoutXAxisAnchor = commandLineView.leadingAnchor
        var leadingConstant: CGFloat = 0

        // Icon (file/dir only): 16x16, leading 13.
        if let icon = item.displayIcon {
            let iv = NSImageView()
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            commandLineView.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                iv.centerYAnchor.constraint(equalTo: commandLineView.centerYAnchor),
                iv.leadingAnchor.constraint(equalTo: commandLineView.leadingAnchor, constant: 13),
            ])
            iconView = iv
            leadingAnchorView = iv.trailingAnchor
            leadingConstant = 0
        }

        // Badge (source dir): size 10 medium .secondary, rounded tertiary
        // fill, .padding(.leading, 6).
        if hasBadge, let badgeText = item.displayBadge {
            let badge = BadgeView(text: badgeText)
            badge.translatesAutoresizingMaskIntoConstraints = false
            commandLineView.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerYAnchor.constraint(equalTo: commandLineView.centerYAnchor),
                badge.leadingAnchor.constraint(equalTo: leadingAnchorView, constant: 6),
            ])
            badgeView = badge
            leadingAnchorView = badge.trailingAnchor
            leadingConstant = 0
        }

        // Display text: size 13, single line, truncating middle.
        textField.stringValue = item.displayText
        textField.font = .systemFont(ofSize: 13)
        // size-13 displayText uses labelColor (NOT secondary), §4.3 mapping.
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.cell?.usesSingleLineMode = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandLineView.addSubview(textField)

        let textLeading = CompletionListLayout.textLeading(hasIcon: hasIcon, hasBadge: hasBadge)
        NSLayoutConstraint.activate([
            commandLineView.topAnchor.constraint(equalTo: topAnchor),
            commandLineView.leadingAnchor.constraint(equalTo: leadingAnchor),
            commandLineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            commandLineView.heightAnchor.constraint(equalToConstant: CompletionListLayout.rowHeight),

            textField.centerYAnchor.constraint(equalTo: commandLineView.centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchorView, constant: textLeading + leadingConstant),
            // trailing Spacer(minLength: 8).
            textField.trailingAnchor.constraint(
                lessThanOrEqualTo: commandLineView.trailingAnchor, constant: -8),
        ])
    }

    // MARK: - In-row detail (verbatim from CompletionListView.swift:125-138)

    private func buildDetailIfSelected() {
        guard isSelected,
            let detail = CompletionListLayout.cleanedDetail(item.displayDetail)
        else {
            // Selected (or not) without a detail → the command line is the
            // whole row; pin its bottom to the row bottom.
            commandLineView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            return
        }

        let field = NSTextField(wrappingLabelWithString: detail)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        // WRAP then truncate the LAST line, matching SwiftUI
        // `.lineLimit(2).truncationMode(.tail)`. On a multiline NSTextField,
        // `.byTruncatingTail` would suppress word-wrapping entirely (the text
        // stays on one line and truncates), contradicting
        // `maximumNumberOfLines = 2`. Keep the `wrappingLabelWithString:`
        // default `.byWordWrapping` and set `truncatesLastVisibleLine` on the
        // cell so the second line gets the trailing ellipsis — mirroring
        // `Components/SelectableText.swift`'s cell config.
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 2
        field.cell?.truncatesLastVisibleLine = true
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        detailField = field

        let hasIcon = item.displayIcon != nil
        let hasBadge = (item.displayBadge?.isEmpty == false)
        let textLeading = CompletionListLayout.textLeading(hasIcon: hasIcon, hasBadge: hasBadge)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: commandLineView.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // minHeight = two lines (detailLineHeight * 2 = 30), bottom pad 6 —
            // matching `.frame(minHeight: 30)` + `.padding(.bottom, 6)`.
            field.heightAnchor.constraint(
                greaterThanOrEqualToConstant: CompletionListLayout.detailLineHeight * 2),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CompletionListLayout.detailBottomPadding),
        ])
    }

    // MARK: - Selection highlight (verbatim from CompletionListView.swift:143)

    private func applyHighlight() {
        // `.background(isSelected ? Color.accentColor.opacity(0.2) : .clear)`.
        layer?.backgroundColor = isSelected ? selectedColor() : NSColor.clear.cgColor
    }

    private func selectedColor() -> CGColor {
        var resolved = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        }
        return resolved
    }

    // MARK: - Dark/light + accent re-resolution (R14)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyHighlight()
        CATransaction.commit()
    }

    // MARK: - Tap-to-confirm (verbatim from CompletionListView.swift:145-148)

    /// `true` while the press began inside the row, tracked across drag events
    /// (NOT a blocking event pump) so the main loop keeps draining.
    private var isPressInside = false

    override func mouseDown(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressInside else { return }
        isPressInside = false
        onClick?(index)
    }

    // MARK: - Badge subview (verbatim from CompletionListView.swift:163-173)

    /// `Text(badge).background(RoundedRectangle(cornerRadius: 3).fill(tertiary.opacity(0.15)))`.
    /// A layer-backed view so the rounded tertiary fill re-resolves on
    /// appearance flip (R14 — `CALayer.cgColor` doesn't auto-flip).
    private final class BadgeView: NSView {
        private let field = NSTextField(labelWithString: "")

        init(text: String) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 3
            field.stringValue = text
            field.font = .systemFont(ofSize: 10, weight: .medium)
            field.textColor = .secondaryLabelColor
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                // `.padding(.horizontal, 4)` + `.padding(.vertical, 1)`.
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                field.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            ])
            applyFill()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        nonisolated deinit {}

        private func applyFill() {
            var resolved = NSColor.tertiaryLabelColor.withAlphaComponent(0.15).cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.tertiaryLabelColor.withAlphaComponent(0.15).cgColor
            }
            layer?.backgroundColor = resolved
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyFill()
            CATransaction.commit()
        }
    }
}
