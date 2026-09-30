import AppKit
import TranscriptKit
import TranscriptWorkspace

/// One tab's content: a find bar over a transcript, with a host of its own.
///
/// **Everything here belongs to this tab alone** — the rows, the scroll
/// position, the selection, the find, a stream or a cold load in flight. Two
/// tabs showing the same script are two transcripts that happen to agree, which
/// is what "editors are independent" means once it is spelled out.
///
/// The find is the host's half of `TranscriptKit` §7: the transcript searches and
/// draws, and this decides when the bar shows, what the count says and when it
/// is trusted.
@MainActor
final class TranscriptEditorViewController: NSViewController {

    let host = DemoHost()
    let transcript = TranscriptView()

    private lazy var findBar: FindBarView = {
        let bar = FindBarView()
        bar.isHidden = true
        return bar
    }()

    /// Reported whenever anything the tool palette shows about this editor moves.
    var onStatusChange: (() -> Void)?

    private(set) var rowCount = 0
    private(set) var isStreaming = false
    private(set) var coldLoadStatus = "\(StressCorpus.sectionCount) distinct documents"

    private var hasLoaded = false

    /// Whether the find bar is showing, or on its way in. The bar's `isHidden`
    /// lags behind this while it slides out.
    private var isFindBarShown = false

    /// Pending removal of the count after the query changed. See `searchStringDidChange`.
    private var countHide: Timer?

    /// How long a changed query's old count may stand before it is taken down.
    private static let countGrace: TimeInterval = 0.2

    /// Room under the last row for the floating tools, so the tail comes to rest
    /// above them rather than behind them.
    static let bottomInset: CGFloat = 96

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureConstraints()

        transcript.dataSource = host
        transcript.delegate = host
        // Host policy: content stops widening at a readable measure and the
        // editor keeps the rest as margin.
        transcript.maxContentWidth = 720
        transcript.contentInsets = NSEdgeInsets(
            top: 12, left: 0, bottom: Self.bottomInset, right: 0)
        host.transcript = transcript
        findBar.delegate = self

        host.onRowCountChange = { [weak self] in self?.update(rowCount: $0) }
        host.onStreamingChange = { [weak self] streaming in
            self?.isStreaming = streaming
            self?.onStatusChange?()
        }
        host.onColdLoadProgress = { [weak self] status in
            self?.coldLoadStatus = status
            self?.onStatusChange?()
        }
        host.onFindChange = { [weak self] matches, isComplete in
            self?.findDidUpdate(matches: matches, isComplete: isComplete)
        }
    }

    /// Mount, lay out, then load — `TranscriptKit` §6. Here and not in
    /// `viewWillAppear()`: there the view is not in the window yet and has no
    /// frame (measured: 0×0 under an `NSTabViewController`), so a load there
    /// measures every row at a width of zero and again at the real one.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasLoaded else { return }
        hasLoaded = true
        view.layoutSubtreeIfNeeded()
        transcript.reloadData()
        update(rowCount: transcript.numberOfRows)
    }

    /// The find bar's top against the view's: zero shows it, minus its height
    /// tucks it under the edge above, with the transcript taking the room back.
    private lazy var findBarTop = findBar.topAnchor.constraint(equalTo: view.topAnchor)

    private func configureHierarchy() {
        // Clipped, so the tucked-away bar is not drawn over what is above.
        view.clipsToBounds = true
        for subview in [transcript, findBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        findBarTop.constant = -findBar.fittingSize.height
        NSLayoutConstraint.activate([
            findBarTop,
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            transcript.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func update(rowCount: Int) {
        self.rowCount = rowCount
        onStatusChange?()
    }

    /// Stops what this tab started. Called when the tab closes, rather than left to
    /// `deinit`: a stream's timer is retained by the run loop and would otherwise
    /// keep firing into nothing.
    func prepareForClose() {
        host.stopStreaming()
        host.cancelColdLoad()
        countHide?.invalidate()
        transcript.endFind()
    }

    // MARK: - Find

    /// The Edit menu's Find items land here, forwarded by the window controller:
    /// `NSTextFinder.Action` as the tag, which is AppKit's own wiring for them.
    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
            let action = NSTextFinder.Action(rawValue: tag)
        else { return }
        perform(action)
    }

    func validateFindItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .nextMatch, .previousMatch: !findBar.searchString.isEmpty
        default: true
        }
    }

    private func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface:
            let wasShown = isFindBarShown
            setFindBarShown(true)
            findBar.beginEditing()
            // Hiding ended the find; the query stayed, as it does in Xcode.
            if !wasShown, !findBar.searchString.isEmpty { searchStringDidChange() }
        case .nextMatch, .previousMatch:
            guard !findBar.searchString.isEmpty else { return }
            if !isFindBarShown {
                // ⌘G with the bar closed brings the find back where it was.
                setFindBarShown(true)
                searchStringDidChange()
            } else if action == .nextMatch {
                transcript.findNext()
            } else {
                transcript.findPrevious()
            }
        case .hideFindInterface:
            setFindBarShown(false)
            transcript.endFind()
            view.window?.makeFirstResponder(nil)
        default:
            break
        }
    }

    /// Slides the bar in or out: its top constraint, through the animator. Only
    /// that moves — the bar's contents and the transcript's are laid out as
    /// ever, the transcript just gets taller or shorter. Hidden once tucked away,
    /// so its field is out of the key view loop.
    private func setFindBarShown(_ shown: Bool) {
        isFindBarShown = shown
        if shown { findBar.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { context.duration = 0 }
            findBarTop.animator().constant = shown ? 0 : -findBar.fittingSize.height
        } completionHandler: { [weak self] in
            // Unless it was shown again before it got there.
            guard let self, !self.isFindBarShown else { return }
            self.findBar.isHidden = true
        }
    }

    /// Hands the new query over, and takes the count down if the walk it starts
    /// has not finished shortly.
    ///
    /// Not straight away. The count beside the old query is wrong for the new one,
    /// but on an ordinary transcript the new walk finishes within a frame or two —
    /// taking the count down on every keystroke would blink it on and off as the
    /// reader types. So the old count gets a moment to be replaced.
    private func searchStringDidChange() {
        countHide?.invalidate()
        countHide = nil
        let query = findBar.searchString
        if query.isEmpty {
            findBar.numberOfMatches = nil
        } else {
            countHide = Timer.scheduledTimer(
                withTimeInterval: Self.countGrace, repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.findBar.numberOfMatches = nil }
            }
        }
        transcript.find(query)
    }

    /// Only a finished walk is shown. A count climbing under the typing is noise,
    /// and a resumed walk — a row streamed in, a row appended — reports incomplete
    /// for a moment before settling where it was.
    private func findDidUpdate(matches: Int, isComplete: Bool) {
        guard isComplete else { return }
        countHide?.invalidate()
        countHide = nil
        findBar.numberOfMatches = findBar.searchString.isEmpty ? nil : matches
    }
}

extension TranscriptEditorViewController: FindBarViewDelegate {

    func findBarView(_ findBarView: FindBarView, didChangeSearchString searchString: String) {
        searchStringDidChange()
    }

    func findBarView(_ findBarView: FindBarView, didRequest action: NSTextFinder.Action) {
        perform(action)
    }
}
