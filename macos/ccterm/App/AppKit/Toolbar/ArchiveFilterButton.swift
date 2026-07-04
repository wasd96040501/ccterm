import AppKit

/// Trailing toolbar item shown only when the Archive tab is selected.
/// A single image-button that opens an `NSPopover` hosting a
/// `FolderFilterPickerViewController`. Pure AppKit — no SwiftUI, no
/// hosting.
///
/// Data comes in via `configure(options:selectedPath:)`; picks go out
/// via the `onSelect` closure the window controller wires in. The view
/// owns the popover's lifetime (it retains one live instance while
/// visible, releases it in `popoverDidClose(_:)`).
@MainActor
final class ArchiveFilterButton: NSView {
    /// Set by the toolbar delegate at construction time. Fires with the
    /// picked path (`nil` for "All Folders").
    var onSelect: ((String?) -> Void)?

    private let button = NSButton()
    private var options: [SessionManager.ArchivedFolder] = []
    private var selectedPath: String?

    /// Retains the currently-visible popover; released on close. `NSPopover`
    /// is not window-retained, so keeping a strong ref here is necessary
    /// while it's on screen.
    private var currentPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
        refreshButtonImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.toolTip = String(localized: "Filter by folder")

        addSubview(button)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Idempotent binding. Every call rewrites both stored properties
    /// and refreshes the button icon so the filled/unfilled state
    /// matches the current `selectedPath` immediately.
    func configure(options: [SessionManager.ArchivedFolder], selectedPath: String?) {
        self.options = options
        self.selectedPath = selectedPath
        refreshButtonImage()
    }

    private func refreshButtonImage() {
        let symbolName =
            selectedPath == nil
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: String(localized: "Filter by folder"))
        image?.isTemplate = true
        button.image = image
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 24) }

    // MARK: - Popover

    @objc private func buttonClicked(_ sender: NSButton) {
        // Toggling the same popover closes it (matches SwiftUI behavior
        // where re-tapping a `Menu` dismisses the same anchor).
        if let popover = currentPopover, popover.isShown {
            popover.close()
            return
        }

        let picker = FolderFilterPickerViewController(
            options: options,
            selectedPath: selectedPath,
            onSelect: { [weak self] path in
                guard let self else { return }
                self.currentPopover?.close()
                self.onSelect?(path)
            })

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = picker
        popover.delegate = self
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        currentPopover = popover
    }

    nonisolated deinit {}
}

extension ArchiveFilterButton: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        currentPopover = nil
    }
}
