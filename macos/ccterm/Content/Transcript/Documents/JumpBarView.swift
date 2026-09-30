import AppKit

/// The 28-pt bar on top of every document beside the transcript: the tile,
/// the path, the stat, and *Show in Transcript* — the way back, always in
/// the same place (design/transcript/02-command.md, 03-file.md).
///
/// A file's path is Xcode's jump bar: when the bar is narrow its folders
/// collapse to `…` from the middle, and the file's name never does.
@MainActor
final class JumpBarView: NSView {
    static let height: CGFloat = 28

    weak var delegate: JumpBarViewDelegate?

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let statFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private var crumbs: [String] = []

    private lazy var tileView: ToolTileView = {
        let tile = ToolTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        return tile
    }()

    private lazy var crumbsLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return label
    }()

    private lazy var statLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Self.statFont
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return label
    }()

    private lazy var backButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = String(localized: "Show in Transcript")
        button.font = Self.font
        button.contentTintColor = .controlAccentColor
        button.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(showInTranscript)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    private let separator = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(separator)
        configureHierarchy()
        configureConstraints()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        addSubview(tileView)
        addSubview(crumbsLabel)
        addSubview(statLabel)
        addSubview(backButton)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            tileView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tileView.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbsLabel.leadingAnchor.constraint(equalTo: tileView.trailingAnchor, constant: 6),
            crumbsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statLabel.leadingAnchor.constraint(equalTo: crumbsLabel.trailingAnchor, constant: 6),
            statLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statLabel.trailingAnchor.constraint(lessThanOrEqualTo: backButton.leadingAnchor, constant: -12),
            backButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            separator.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Content

    /// The tile in the call's state, the path, the stat.
    func configure(with header: DocumentHeader) {
        tileView.tile = header.tile
        crumbs = header.crumbs
        statLabel.attributedStringValue = header.stat.attributedString(font: Self.statFont, color: .secondaryLabelColor)
        statLabel.isHidden = header.stat.isEmpty
        setAccessibilityLabel(header.crumbs.joined(separator: " › "))
        shownFolders = nil
        showCrumbs(keeping: Array(crumbs.indices.dropLast()))
        needsLayout = true
    }

    @objc private func showInTranscript() {
        delegate?.jumpBarViewShowInTranscript(self)
    }

    // MARK: - Crumbs

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        fitCrumbs()
    }

    /// The most of the path that fits: every crumb, then the middle ones
    /// folded into `…` one at a time, never the first and never the last.
    private func fitCrumbs() {
        guard crumbs.count > 1 else { return }
        let statWidth = statLabel.isHidden ? 0 : statLabel.frame.width
        let room = backButton.frame.minX - 12 - statWidth - 6 - crumbsLabel.frame.minX
        guard room > 0 else { return }
        var kept = Array(crumbs.indices.dropLast())
        while kept.count > 1, Self.attributed(crumbs, keeping: kept).size().width > room {
            kept.remove(at: kept.count / 2)
        }
        if kept.count == 1, Self.attributed(crumbs, keeping: kept).size().width > room { kept = [] }
        showCrumbs(keeping: kept)
    }

    private var shownFolders: [Int]?

    private func showCrumbs(keeping folders: [Int]) {
        guard folders != shownFolders else { return }
        shownFolders = folders
        crumbsLabel.attributedStringValue = Self.attributed(crumbs, keeping: folders)
        crumbsLabel.lineBreakMode = crumbs.count > 1 && folders.isEmpty ? .byTruncatingHead : .byTruncatingTail
    }

    /// The crumbs at `kept` (indices of folders) and the last, with `…`
    /// where some were left out.
    private static func attributed(_ crumbs: [String], keeping kept: [Int]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let separator = NSAttributedString(
            string: " › ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        func append(_ text: String, color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        var next = 0
        for index in kept {
            if index > next {
                append("…", color: .secondaryLabelColor)
                result.append(separator)
            }
            append(crumbs[index], color: .secondaryLabelColor)
            result.append(separator)
            next = index + 1
        }
        if next < crumbs.count - 1 {
            append("…", color: .secondaryLabelColor)
            result.append(separator)
        }
        if let last = crumbs.last { append(last, color: .labelColor) }
        return result
    }
}
