import AppKit

/// An editor's find bar, laid out as Xcode's is: one field running the width of
/// the editor — magnifier, query, match count, clear — then the two arrows and
/// Done.
///
/// **Dumb, like any view here.** It shows the query and the count it is handed and
/// reports everything else to its delegate; it has never heard of what it is
/// searching. When it is shown, and what a count means, is the editor's.
///
/// **What Xcode's has and this does not**: the Find/Replace mode, the history
/// button, case sensitivity and the Contains/Starts With menu. Each is a control
/// with nothing behind it until a find can take options — a transcript's folds
/// case and diacritics, the way a find bar's search is expected to, and takes no
/// options — and a control that does nothing is worse than an absent one.
///
/// The demo's, not the workspace's: an editor area is a split and tabs, and what
/// a tab puts over its content is the tab's.
@MainActor
final class FindBarView: NSView {

    weak var delegate: FindBarViewDelegate?

    /// The query. Setting it does not report a change: the host setting its own
    /// query needs no telling.
    var searchString: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            updateClearButton()
        }
    }

    /// The count shown at the field's trailing end, or `nil` for none — while a
    /// search has not settled, and beside an empty field.
    var numberOfMatches: Int? {
        didSet { updateCount() }
    }

    /// Fixed, so an editor can lay out around the bar before it has drawn.
    static let height: CGFloat = 32

    lazy var field: NSTextField = {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "Find", bundle: .module)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = fieldDelegate
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }()

    lazy var countLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isHidden = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    lazy var clearButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "Clear", bundle: .module))
        button.contentTintColor = .tertiaryLabelColor
        button.target = self
        button.action = #selector(clear)
        button.isHidden = true
        return button
    }()

    lazy var navigation: NSSegmentedControl = {
        let control = NSSegmentedControl(
            images: [
                NSImage(
                    systemSymbolName: "chevron.left",
                    accessibilityDescription: String(localized: "Previous", bundle: .module))!,
                NSImage(
                    systemSymbolName: "chevron.right",
                    accessibilityDescription: String(localized: "Next", bundle: .module))!,
            ],
            trackingMode: .momentary, target: self, action: #selector(navigate))
        control.isEnabled = false
        return control
    }()

    lazy var doneButton: NSButton = {
        let button = NSButton(
            title: String(localized: "Done", bundle: .module), target: self,
            action: #selector(done))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var magnifier: NSImageView = {
        let view = NSImageView(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        view.contentTintColor = .secondaryLabelColor
        return view
    }()

    private lazy var fieldBox = FieldBox()

    /// The field's delegate, so that being one is not part of this view's surface.
    private lazy var fieldDelegate = FieldDelegate(bar: self)

    private lazy var separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        return box
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    private func configureHierarchy() {
        for view in [magnifier, field, countLabel, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            fieldBox.addSubview(view)
        }
        for view in [fieldBox, navigation, doneButton, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            fieldBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fieldBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 22),
            navigation.leadingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: 8),
            navigation.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            magnifier.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 6),
            magnifier.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            countLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: field.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            clearButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
            clearButton.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The query takes whatever the count does not.
        let fill = field.trailingAnchor.constraint(
            equalTo: countLabel.leadingAnchor, constant: -6)
        fill.priority = .defaultLow
        fill.isActive = true
    }

    /// Puts the caret in the field with the query selected, so typing replaces it
    /// and Return repeats it — ⌘F's behaviour in every Mac find bar. The field
    /// selects its text on taking the focus, and takes it again when the caret
    /// is already there, so there is nothing to select by hand.
    func beginEditing() {
        window?.makeFirstResponder(field)
    }

    // MARK: - Showing

    private func updateCount() {
        navigation.isEnabled = (numberOfMatches ?? 0) > 0
        guard let count = numberOfMatches, !searchString.isEmpty else { return hideCount() }
        countLabel.stringValue =
            switch count {
            case 0: String(localized: "No matches", bundle: .module)
            case 1: String(localized: "1 match", bundle: .module)
            default: String(localized: "\(count) matches", bundle: .module)
            }
        countLabel.isHidden = false
    }

    private func updateClearButton() {
        clearButton.isHidden = searchString.isEmpty
        if searchString.isEmpty { hideCount() }
    }

    /// Emptied as well as hidden: a hidden label still takes its width from its
    /// text, and the query should have the room back.
    private func hideCount() {
        countLabel.stringValue = ""
        countLabel.isHidden = true
    }

    // MARK: - Reporting

    fileprivate func fieldTextDidChange() {
        updateClearButton()
        delegate?.findBarView(self, didChangeSearchString: searchString)
    }

    /// Return steps to the next match and Shift-Return to the previous, which is
    /// Xcode's binding and Safari's; both arrive as `insertNewline(_:)`, so the
    /// modifier is read off the event. Escape is Done.
    fileprivate func fieldDoCommand(by commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            delegate?.findBarView(self, perform: backward ? .previousMatch : .nextMatch)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.findBarView(self, perform: .hideFindInterface)
            return true
        default:
            return false
        }
    }

    @objc private func clear() {
        searchString = ""
        delegate?.findBarView(self, didChangeSearchString: "")
        window?.makeFirstResponder(field)
    }

    @objc private func navigate() {
        delegate?.findBarView(
            self, perform: navigation.selectedSegment == 0 ? .previousMatch : .nextMatch)
    }

    @objc private func done() {
        delegate?.findBarView(self, perform: .hideFindInterface)
    }
}

/// The query field's `NSTextFieldDelegate`, passing what the field reports to
/// the bar it belongs to.
@MainActor
private final class FieldDelegate: NSObject, NSTextFieldDelegate {

    private unowned let bar: FindBarView

    init(bar: FindBarView) {
        self.bar = bar
    }

    func controlTextDidChange(_ notification: Notification) {
        bar.fieldTextDidChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        bar.fieldDoCommand(by: commandSelector)
    }
}

/// The rounded field the query sits in, drawn the way a text field's bezel is.
@MainActor
private final class FieldBox: NSView {

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    /// Colours are resolved here rather than once, so they follow the appearance.
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}
