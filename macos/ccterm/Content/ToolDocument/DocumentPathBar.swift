import AppKit
import UniformTypeIdentifiers

/// The bar over a document, Xcode's jump bar: where the document is — a file's
/// folders down to the file, each with its Finder icon, or the document's
/// symbol and title — and at the trailing end what changed and the arrows
/// that step through the changes.
///
/// Pressing a path component shows it in the Finder, when it is on disk.
@MainActor
final class DocumentPathBar: NSView {
    static let height: CGFloat = 28

    /// The reader stepped to the previous (`-1`) or next (`+1`) change.
    var onStep: ((_ direction: Int) -> Void)?

    private let pathControl = NSPathControl()
    private let statusLabel = NSTextField(labelWithString: "")
    private let stepper = NSSegmentedControl()
    private let separator = NSBox()
    /// The file behind each path item, in order.
    private var itemURLs: [URL?] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        pathControl.pathStyle = .standard
        pathControl.font = .systemFont(ofSize: 12)
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.backgroundColor = .clear
        pathControl.target = self
        pathControl.action = #selector(revealClickedItem(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stepper.segmentCount = 2
        stepper.trackingMode = .momentary
        stepper.segmentStyle = .separated
        stepper.controlSize = .small
        stepper.setImage(NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil), forSegment: 0)
        stepper.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil), forSegment: 1)
        stepper.setToolTip(String(localized: "Previous Change"), forSegment: 0)
        stepper.setToolTip(String(localized: "Next Change"), forSegment: 1)
        stepper.target = self
        stepper.action = #selector(step(_:))
        stepper.setContentCompressionResistancePriority(.required, for: .horizontal)

        separator.boxType = .separator

        let stack = NSStackView(views: [pathControl, statusLabel, stepper])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Content

    /// A file's path, from the home folder (or the root) down to the file.
    func showPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        var components = url.standardizedFileURL.pathComponents
        var base = URL(fileURLWithPath: "/")
        if components.starts(with: home) {
            base = FileManager.default.homeDirectoryForCurrentUser
            components.removeFirst(home.count)
        } else {
            components.removeFirst()
        }
        var items: [NSPathControlItem] = []
        itemURLs = []
        var current = base
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            current = current.appendingPathComponent(component, isDirectory: !isLast)
            let item = NSPathControlItem()
            item.title = component
            item.image = Self.icon(for: current, isFolder: !isLast)
            items.append(item)
            itemURLs.append(current)
        }
        pathControl.pathItems = items
        pathControl.toolTip = String(localized: "Show in Finder")
    }

    /// A document that is not a file: its symbol and title.
    func showTitle(_ title: String, symbol: String) {
        let item = NSPathControlItem()
        item.title = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        pathControl.pathItems = [item]
        pathControl.toolTip = nil
        itemURLs = [nil]
    }

    /// The trailing status — `+12 −3`, `Exit Code 1` — or none.
    func setStatus(_ status: NSAttributedString?) {
        statusLabel.attributedStringValue = status ?? NSAttributedString()
        statusLabel.isHidden = status == nil
    }

    /// Shows the change arrows when there is more than one change to step to.
    func setStepsChanges(_ steps: Bool) {
        stepper.isHidden = !steps
    }

    // MARK: - Actions

    @objc private func revealClickedItem(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem,
            let index = sender.pathItems.firstIndex(where: { $0 === clicked }),
            let url = itemURLs[index], FileManager.default.fileExists(atPath: url.path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func step(_ sender: NSSegmentedControl) {
        onStep?(sender.selectedSegment == 0 ? -1 : 1)
    }

    // MARK: - Icons

    private static func icon(for url: URL, isFolder: Bool) -> NSImage {
        let image: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if isFolder {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .plainText)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
