import AppKit

@testable import ccterm

/// Test-only minimal `NSViewController` that mounts only the transcript
/// — no control panel, no input bar, no sheet presenter. Used by
/// snapshot tests that want a clean transcript bitmap with a custom
/// pre-seeded controller fixture (e.g.
/// `UserAttachmentsSnapshotTests`).
///
/// The mount goes through the same canonical attach pattern documented
/// on `TranscriptScrollViewFactory` (make / addSubview /
/// layoutSubtreeIfNeeded / bindData) — same pattern production's
/// `ChatSessionViewController.attachSession` uses — so a snapshot
/// taken here reflects the same row geometry the production transcript
/// would render at the same width.
@MainActor
final class TranscriptOnlyHostViewController: NSViewController {

    let controller: Transcript2Controller

    init(controller: Transcript2Controller) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var scroll: Transcript2ScrollView?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        controller.scrollToTail()
        self.scroll = scroll
    }
}
