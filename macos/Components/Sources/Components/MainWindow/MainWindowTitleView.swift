import AppKit
import UniformTypeIdentifiers

/// The main window's title, as Xcode's toolbar shows it: the project's folder
/// icon and name, and under it the project's git branch.
///
/// Not the window's own `title` / `subtitle`: AppKit lays a title out alone
/// (15-point semibold, centred) until a subtitle arrives and then again as two
/// lines (13-point bold over 11-point), in one frame and without animation — and
/// the branch is read off the main thread, so it can come and go on its own.
/// Here the lines are in the fonts AppKit uses for a title with a subtitle, and
/// the change animates: the name, centred alone, rises as the branch fades in
/// under it, one constraint and one alpha through their animators.
public final class MainWindowTitleView: NSView {

    /// The project's name, or `nil` to show nothing.
    public var title: String? {
        didSet {
            titleField.stringValue = title ?? ""
            isHidden = title == nil
        }
    }

    /// The project's branch. Without one the name is centred; one arriving
    /// raises the name and fades in under it, and one leaving does the reverse.
    /// A branch replacing another is just written.
    public var subtitle: String? {
        didSet {
            guard subtitle != oldValue else { return }
            // One leaving keeps its text while it fades.
            if let subtitle { subtitleField.stringValue = subtitle }
            guard (subtitle == nil) != (oldValue == nil) else { return }
            let shown = subtitle != nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration =
                    isHidden || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.duration
                titleCentre.animator().constant = shown ? -Self.lift : 0
                subtitleField.animator().alphaValue = shown ? 1 : 0
            }
        }
    }

    private static let duration: TimeInterval = 0.25

    /// How far the name rises for a branch: half the branch's line, so the two
    /// lines together are centred as the name alone was.
    private static let lift = subtitleLineHeight / 2

    /// AppKit's lines for a title over a subtitle (measured).
    private static let titleLineHeight: CGFloat = 16
    private static let subtitleLineHeight: CGFloat = 14

    /// The name's centre against the view's: 0 alone, `-lift` over a branch.
    private lazy var titleCentre = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)

    private lazy var iconView: NSImageView = {
        let view = NSImageView(image: NSWorkspace.shared.icon(for: .folder))
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private lazy var titleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .boldSystemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        return field
    }()

    private lazy var subtitleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.alphaValue = 0
        return field
    }()

    public init() {
        super.init(frame: .zero)
        isHidden = true
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        for subview in [iconView, titleField, subtitleField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    /// Icon, then the two lines stacked tight, the branch's hanging from the
    /// name's: tall enough for both, with the name centred until a branch comes.
    private func configureConstraints() {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.titleLineHeight + Self.subtitleLineHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleCentre,
            titleField.heightAnchor.constraint(equalToConstant: Self.titleLineHeight),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor),
            subtitleField.heightAnchor.constraint(equalToConstant: Self.subtitleLineHeight),
        ])
    }
}
