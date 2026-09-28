import AppKit

/// One tool call in a card: its symbol, what happened, where, and how it
/// went — `+12 −3`, `Exit 1` — with a chevron when it opens something.
///
/// A press opens its document beside the transcript as the temporary tab; a
/// double-click keeps it; the context menu offers both and copies what the
/// step was about.
@MainActor
final class ToolStepRowView: PressableRowView {
    static let height: CGFloat = 28

    /// Asked to open the step's document; `pinned` for a tab that stays.
    var onOpen: ((_ pinned: Bool) -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var step: ToolStep?

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureViews()
        onClick = { [weak self] clickCount in self?.onOpen?(clickCount > 1) }
    }

    func configure(with step: ToolStep) {
        self.step = step
        resetHighlight()
        isPressable = step.document != nil
        let failed = step.outcome == .failed
        icon.image = NSImage(systemSymbolName: step.symbol, accessibilityDescription: nil)
        icon.contentTintColor = failed ? .systemRed : .secondaryLabelColor
        titleLabel.stringValue = step.title
        titleLabel.textColor = step.outcome == .stopped ? .secondaryLabelColor : .labelColor
        detailLabel.stringValue = step.detail ?? ""
        detailLabel.isHidden = step.detail == nil
        detailLabel.font =
            step.detailIsCode
            ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = step.detailIsCode ? .byTruncatingTail : .byTruncatingMiddle
        statLabel.attributedStringValue = Self.attributed(step.stat, outcome: step.outcome)
        statLabel.isHidden = statLabel.attributedStringValue.length == 0
        chevron.isHidden = step.document == nil
        toolTip = [step.title, step.detail].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel(
            [step.title, step.detail, statLabel.stringValue.isEmpty ? nil : statLabel.stringValue]
                .compactMap { $0 }.joined(separator: ", "))
    }

    /// `+12 −3` in green and red, or a note — red when the step failed.
    static func attributed(_ stat: ToolStep.Stat?, outcome: ToolStep.Outcome) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let result = NSMutableAttributedString()
        switch stat {
        case .lines(let added, let removed)?:
            if added > 0 || removed == 0 {
                result.append(
                    NSAttributedString(
                        string: "+\(added)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
            }
            if removed > 0 {
                if result.length > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: font])) }
                result.append(
                    NSAttributedString(
                        string: "−\(removed)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
            }
        case .note(let note)?:
            let color: NSColor = outcome == .failed ? .systemRed : .secondaryLabelColor
            result.append(NSAttributedString(string: note, attributes: [.font: font, .foregroundColor: color]))
        case nil:
            if outcome == .failed {
                result.append(
                    NSAttributedString(
                        string: String(localized: "Failed"),
                        attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
            } else if outcome == .stopped {
                result.append(
                    NSAttributedString(
                        string: String(localized: "Stopped"),
                        attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        return result
    }

    // MARK: - Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let step else { return nil }
        let menu = NSMenu()
        if step.document != nil {
            menu.addItem(item(String(localized: "Open"), #selector(openTemporary(_:))))
            menu.addItem(item(String(localized: "Open in New Tab"), #selector(openPinned(_:))))
        }
        if let copyable = copyable(step) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let copy = item(copyable.title, #selector(copyValue(_:)))
            copy.representedObject = copyable.value
            menu.addItem(copy)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// What Copy puts on the pasteboard: the full command, or the file's path.
    private func copyable(_ step: ToolStep) -> (title: String, value: String)? {
        switch step.document?.content {
        case .command(let command)?:
            return command.command.map { (String(localized: "Copy Command"), $0) }
        default:
            return step.document?.path.map { (String(localized: "Copy Path"), $0) }
        }
    }

    @objc private func openTemporary(_ sender: Any?) { onOpen?(false) }
    @objc private func openPinned(_ sender: Any?) { onOpen?(true) }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - Building

    private func configureViews() {
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for label in [titleLabel, detailLabel, statLabel] {
            label.cell?.usesSingleLineMode = true
            label.isSelectable = false
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, titleLabel, detailLabel, spacer, statLabel, chevron])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(8, after: statLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            chevron.widthAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
