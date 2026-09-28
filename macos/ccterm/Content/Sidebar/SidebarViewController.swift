import AppKit
import Combine

/// The main window's sidebar: the session library as an Xcode-style source
/// list — projects, their sessions, and under each session its subagents and
/// workflow runs, every row an icon and a title. Opening a row that has a
/// transcript is reported to the delegate; groups only expand.
@MainActor
final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    private let library: LibraryStore
    private var cancellables = Set<AnyCancellable>()

    /// The concrete store rather than a protocol: it has one implementation,
    /// and `LibraryStore(root:)` over a fixture directory is the test seam.
    init(library: LibraryStore) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        library.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nodes in self?.show(nodes) }
            .store(in: &cancellables)
    }

    private func show(_ nodes: [LibraryNode]) {}
}
