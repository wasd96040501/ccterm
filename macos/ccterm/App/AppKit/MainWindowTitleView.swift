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
@MainActor
final class MainWindowTitleView: NSView {

    /// The project's name, or `nil` to show nothing.
    var title: String? {
        didSet {
            titleField.stringValue = title ?? ""
            isHidden = title == nil
        }
    }

    /// The project's branch. Without one the name is centred; one arriving
    /// raises the name and fades in under it, and one leaving does the reverse.
    /// A branch replacing another is just written.
    var subtitle: String? {
        didSet {
            guard subtitle != oldValue else { return }
            subtitleField.stringValue = subtitle ?? ""
            guard subtitle != nil else {
                subtitleField.alphaValue = 0
                return
            }
            guard oldValue == nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration =
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.fadeDuration
                subtitleField.animator().alphaValue = 1
            }
        }
    }

    private static let fadeDuration: TimeInterval = 0.25

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

    init() {
        super.init(frame: .zero)
        isHidden = true
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        for subview in [iconView, titleField, subtitleField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    /// Icon, then the two lines stacked tight — AppKit's 16-point title line over
    /// its 14-point subtitle line. The subtitle's line is there empty or not.
    private func configureConstraints() {
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor),
            titleField.heightAnchor.constraint(equalToConstant: 16),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor),
            subtitleField.heightAnchor.constraint(equalToConstant: 14),
            subtitleField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
