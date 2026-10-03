import AppKit
import Components
import DisplayModels

/// A tab of the playground's editor area, laid out as the app's
/// `SessionTabViewController` lays out its own: a session's transcript with the
/// dock and the composer floating over it — 720 wide at most, 16 from the
/// tab's bottom edge and from each side when the tab is narrower — or, as a
/// draft, the New view with the composer in its `composerGuide`. The words and
/// states are fixtures; what the composer and the New view report changes
/// nothing but the New view's own choices.
final class PlaygroundTab: NSViewController {
    enum Start {
        case session(entries: [PlaygroundEntry], composer: ComposerPresentation)
        case draft(NewSessionContent)
    }

    private let start: Start
    private let composer = ComposerViewController()
    private let dock = ComposerDockView()
    private var transcript: PlaygroundTranscript?
    private var newSession: NewSessionViewController?
    private var draft: NewSessionContent?

    /// How far the floating composer stands from the tab's bottom edge, and
    /// its width (`SessionTabViewController.floatGap`, `.composerWidth`).
    private static let floatGap: CGFloat = 16
    private static let composerWidth: CGFloat = 720

    init(_ start: Start, title: String) {
        self.start = start
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        dock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dock, positioned: .below, relativeTo: composer.view)
        NSLayoutConstraint.activate([
            dock.topAnchor.constraint(equalTo: composer.view.topAnchor, constant: -ComposerDockView.fade),
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        switch start {
        case .session(let entries, let presentation):
            composer.configure(with: presentation)
            mountSession(entries)
        case .draft(let content):
            composer.configure(with: ComposerFixtures.newTab)
            mountDraft(content)
        }
    }

    /// What the floating composer covers is the transcript's safe area: the
    /// card and the float under it.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let transcript else { return }
        let covered = composer.view.frame.height + Self.floatGap
        if transcript.view.additionalSafeAreaInsets.bottom != covered {
            transcript.view.additionalSafeAreaInsets.bottom = covered
        }
    }

    private func mountSession(_ entries: [PlaygroundEntry]) {
        let transcript = PlaygroundTranscript(entries: entries)
        self.transcript = transcript
        addChild(transcript)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view, positioned: .below, relativeTo: dock)
        let width = composer.view.widthAnchor.constraint(equalToConstant: Self.composerWidth)
        width.priority = .wishUnderWindowSize
        NSLayoutConstraint.activate([
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.floatGap),
            composer.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            composer.view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.composerWidth),
            composer.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.floatGap),
            width,
        ])
    }

    /// The New view filling the tab, the composer in its slot, which takes
    /// the composer's height.
    private func mountDraft(_ content: NewSessionContent) {
        let newSession = NewSessionViewController()
        newSession.delegate = self
        self.newSession = newSession
        draft = content
        addChild(newSession)
        newSession.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newSession.view, positioned: .below, relativeTo: dock)
        dock.isHidden = true
        let guide = newSession.composerGuide
        NSLayoutConstraint.activate([
            newSession.view.topAnchor.constraint(equalTo: view.topAnchor),
            newSession.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newSession.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newSession.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.view.topAnchor.constraint(equalTo: guide.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            guide.heightAnchor.constraint(equalTo: composer.view.heightAnchor),
        ])
        newSession.configure(with: content)
    }
}

// MARK: - The New view's choices

extension PlaygroundTab: NewSessionViewControllerDelegate {
    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL) {
        guard var draft else { return }
        draft.folderTitle = url.lastPathComponent
        draft.folderPath = (url.path as NSString).abbreviatingWithTildeInPath
        show(draft)
    }

    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController) {
        guard var draft, case .repository(let title, let on) = draft.branchRow else { return }
        draft.branchRow = .repository(branchTitle: title, usesWorktree: !on)
        draft.explanation = on ? nil : "A new branch from \(title), in a new worktree"
        show(draft)
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, branchMenuMatching query: String
    ) -> MenuContent? {
        MenuFixtures.branch(query: query)
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranchItem id: AnyHashable
    ) {
        guard var draft, case .repository(_, let on) = draft.branchRow, let name = id.base as? String else { return }
        draft.branchRow = .repository(branchTitle: name, usesWorktree: on)
        show(draft)
    }

    private func show(_ content: NewSessionContent) {
        draft = content
        newSession?.configure(with: content)
    }
}
