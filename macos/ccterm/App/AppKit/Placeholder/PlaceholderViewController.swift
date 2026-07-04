import AppKit

/// Shared base for the "not-yet-migrated" placeholder view controllers.
/// Renders a full-pane vibrancy backdrop with a centered, single-line
/// message. The message is injected via `init(message:)` — subclasses
/// exist only so `DetailFlowCoordinator` can pattern-match on VC kind
/// and give each mount its own name in stack traces / logs.
///
/// This is a `DetailContainerChild`; `prepareForRemoval()` is a no-op
/// because a placeholder has no per-attach subscriptions or timers.
///
/// The concrete AppKit Archive / New Session / Settings / About views
/// will eventually replace these placeholders in follow-up PRs. Until
/// then the placeholder makes the missing feature legible instead of
/// crashing on a nil-hosted SwiftUI view.
@MainActor
class PlaceholderViewController: NSViewController, DetailContainerChild {
    private let message: String
    private let backdrop = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        backdrop.material = .contentBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        view = backdrop

        label.stringValue = message
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        backdrop.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: backdrop.trailingAnchor, constant: -24),
        ])
    }

    func prepareForRemoval() {}
}
