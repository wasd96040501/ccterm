import AppKit

/// Shared base for the three sidebar row types. Adds a fixed-width
/// "icon slot" anchored at the leading edge so heterogeneous rows
/// align icon-to-icon and text-to-text. The slot is vertically
/// centered against the cell so per-row `heightOfRowByItem` overrides
/// — needed to match the prior SwiftUI sidebar's three different row
/// heights — fall through cleanly.
class SidebarCellViewBase: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")

    let iconSlot: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    init(leadingInset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconSlot)
        NSLayoutConstraint.activate([
            iconSlot.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: leadingInset),
            iconSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconSlot.widthAnchor.constraint(
                equalToConstant: SidebarLayout.iconSlotWidth),
            iconSlot.heightAnchor.constraint(
                equalToConstant: SidebarLayout.iconSlotWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Fixed row

/// Renders a fixed top-of-sidebar item: SF Symbol icon + title.
final class SidebarFixedCellView: SidebarCellViewBase {

    init() {
        super.init(leadingInset: SidebarLayout.leadingInset)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureSubviews() {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarLayout.iconFont.pointSize, weight: .regular)
        iconSlot.addSubview(icon)
        // Bind to the NSTableCellView `imageView` outlet so the source
        // list style updates its tint automatically with background style.
        imageView = icon

        let title = NSTextField(labelWithString: "")
        Self.configureSingleLineTitle(title)
        addSubview(title)
        textField = title

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),

            title.leadingAnchor.constraint(
                equalTo: iconSlot.trailingAnchor, constant: SidebarLayout.iconTextSpacing),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -SidebarLayout.trailingInset),
            title.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])
    }

    func configure(kind: FixedKind) {
        imageView?.image = NSImage(
            systemSymbolName: kind.systemImage, accessibilityDescription: nil)
        textField?.stringValue = kind.title
    }

    /// Belt-and-suspenders single-line + truncate-tail config. Shared
    /// across all three row types so a title that overflows the
    /// column NEVER wraps to a second line (which would overflow the
    /// fixed `heightOfRowByItem` and bleed into adjacent rows).
    ///
    /// `NSTextField(labelWithString:)` constructs a multi-line label by
    /// default (`cell.wraps = true`, `cell.isScrollable = false`).
    /// Setting `usesSingleLineMode = true` on the field alone does not
    /// reliably override the cell-level wraps flag — both need to be
    /// flipped explicitly.
    static func configureSingleLineTitle(_ title: NSTextField) {
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = SidebarLayout.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.cell?.wraps = false
        title.cell?.isScrollable = false
        title.cell?.usesSingleLineMode = true
        title.cell?.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
    }
}

// MARK: - Folder header

/// Folder grouping header: folder icon + dim title + spacer + chevron.
/// Click anywhere on the row to toggle (the outline view's action
/// handler does the work — folder rows are non-selectable, but
/// `outlineView.action` still fires on click).
final class SidebarFolderCellView: SidebarCellViewBase {

    /// External flag — set by the controller in `viewFor`. Drives
    /// chevron rotation, animated or immediate depending on `setExpanded`.
    private(set) var isExpanded: Bool = true
    private let chevron = NSImageView()

    init() {
        super.init(leadingInset: SidebarLayout.leadingInset)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureSubviews() {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarLayout.iconFont.pointSize, weight: .regular)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        iconSlot.addSubview(icon)
        imageView = icon

        let title = NSTextField(labelWithString: "")
        SidebarFixedCellView.configureSingleLineTitle(title)
        title.textColor = .secondaryLabelColor
        addSubview(title)
        textField = title

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleProportionallyDown
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarLayout.chevronFont.pointSize, weight: .semibold)
        chevron.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        addSubview(chevron)

        // Let the title shrink before the chevron does, and never let
        // the title push the chevron out of view.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),

            title.leadingAnchor.constraint(
                equalTo: iconSlot.trailingAnchor, constant: SidebarLayout.iconTextSpacing),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: chevron.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),

            chevron.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -SidebarLayout.trailingInset),
            chevron.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(folderName: String, isExpanded: Bool) {
        textField?.stringValue = folderName
        self.isExpanded = isExpanded
        updateChevronImage()
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if animated {
            // Crossfade between the two SF Symbol variants.
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.wantsLayer = true
            chevron.layer?.add(transition, forKey: "chevronFade")
        }
        updateChevronImage()
    }

    private func updateChevronImage() {
        // Swap between `chevron.right` and `chevron.down` rather than
        // rotating: NSImageView + SF Symbols renders these directly,
        // no autolayout / pivot juggling, no animation invariants to
        // get wrong.
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

// MARK: - History row

/// Per-session history entry. The leading status indicator (running
/// dots / unread dot / placeholder) sits in the 16pt slot; the title
/// follows after the standard 6pt gap and can shimmer + crossfade.
final class SidebarHistoryCellView: SidebarCellViewBase {

    private let statusIndicator = SidebarStatusIndicatorView(
        frame: CGRect(
            x: 0, y: 0,
            width: SidebarLayout.iconSlotWidth,
            height: SidebarLayout.iconSlotWidth))
    private let title = CrossfadingTextField(labelWithString: "")
    private var shimmerOverlay: ShimmerOverlay?

    /// Identity of the session this cell is currently observing. Set by
    /// the controller in `configureHistoryCell`; cleared in
    /// `prepareForReuse` so the controller can detect cell recycle.
    var observedSessionId: String?

    /// First-message-derived placeholder. Used when `Session.title`
    /// hasn't been generated yet.
    var fallbackTitle: String = ""

    init() {
        super.init(leadingInset: SidebarLayout.leadingInset)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        observedSessionId = nil
        shimmerOverlay?.stop()
    }

    private func configureSubviews() {
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(statusIndicator)

        SidebarFixedCellView.configureSingleLineTitle(title)
        addSubview(title)
        textField = title

        NSLayoutConstraint.activate([
            statusIndicator.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            statusIndicator.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),

            title.leadingAnchor.constraint(
                equalTo: iconSlot.trailingAnchor, constant: SidebarLayout.iconTextSpacing),
            title.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SidebarLayout.trailingInset),
            title.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])
    }

    func configure(
        title newTitle: String,
        isRunning: Bool,
        hasUnread: Bool,
        isGeneratingTitle: Bool
    ) {
        title.setStringValue(newTitle, animated: window != nil)
        statusIndicator.update(isRunning: isRunning, hasUnread: hasUnread)
        if isGeneratingTitle {
            if shimmerOverlay == nil {
                shimmerOverlay = ShimmerOverlay(host: title)
            }
            shimmerOverlay?.start()
        } else {
            shimmerOverlay?.stop()
        }
    }
}
