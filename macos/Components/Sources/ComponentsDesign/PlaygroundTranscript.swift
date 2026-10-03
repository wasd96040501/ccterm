import AppKit
import Components
import DisplayModels
import TranscriptKit

/// What a playground session's transcript shows, as the app's page would have
/// it: prompts and replies are TranscriptKit's own rows; a run is its line,
/// the items it discloses, and the approval card of a call waiting for the
/// reader — the package's `.view` rows.
enum PlaygroundEntry {
    case prompt(String)
    case reply(String)
    /// A run's line, the lines of its items (a run of one is the item itself),
    /// and the card of the call waiting for the reader, if any.
    case run(id: String, line: WorkLine, items: [WorkLine], waiting: Approval?)
}

/// A session's transcript in a `TranscriptView`, wired as the app's
/// `TranscriptViewController` wires its own (`PageRow`, `PageRow+View`,
/// `Bubble+UserMessage`): the same column, insets and gaps, each `.view` row
/// its real row view measured by its own height, a run opening and closing in
/// place. It loads once it is in its window at its width — mount, lay out,
/// then load (`TranscriptKit` §5) — and shows the end, as a session tab does.
/// The reader's safe area is what the floating composer covers.
final class PlaygroundTranscript: NSViewController {
    private let entries: [PlaygroundEntry]
    private let transcript = TranscriptView()
    private var rows: [Row] = []
    private var expanded: Set<String> = []
    private var hasLoaded = false

    /// The app's column (`TranscriptViewController`): 720 at most, 12 over
    /// the first row, 24 under the last above the safe area.
    private static let maxContentWidth: CGFloat = 720
    private static let topGap: CGFloat = 12
    private static let bottomGap: CGFloat = 24

    init(entries: [PlaygroundEntry]) {
        self.entries = entries
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = SafeAreaView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        transcript.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        transcript.maxContentWidth = Self.maxContentWidth
        transcript.contentInsets = NSEdgeInsets(top: Self.topGap, left: 0, bottom: Self.bottomGap, right: 0)
        transcript.dataSource = self
        transcript.delegate = self
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadIfLaidOut()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bottom = Self.bottomGap + view.safeAreaInsets.bottom
        if transcript.contentInsets.bottom != bottom { transcript.contentInsets.bottom = bottom }
        // A view in no view controller tree may never be told it appeared:
        // the first layout in a window loads it, a turn later, out of layout.
        if !hasLoaded { DispatchQueue.main.async { [weak self] in self?.loadIfLaidOut() } }
    }

    private func loadIfLaidOut() {
        guard !hasLoaded, view.window != nil else { return }
        view.layoutSubtreeIfNeeded()
        guard transcript.bounds.width > 0 else { return }
        hasLoaded = true
        rows = entries.enumerated().flatMap { Self.rows(of: $1, at: $0, expanded: expanded) }
        transcript.reloadData()
        if !rows.isEmpty { transcript.scrollToRow(at: rows.count - 1, scrollPosition: .bottom) }
    }

    // MARK: - Rows

    struct Row {
        enum Kind {
            case prompt(String)
            case reply(String)
            case work(WorkLineRowView.Model)
            case approval(Approval)
        }
        /// The entry's index and which of its rows.
        let id: String
        let entry: Int
        let kind: Kind

        /// The room above and below a line of work's words inside its box.
        var air: CGFloat {
            if case .work = kind { WorkLineRowView.air } else { 0 }
        }
    }

    private static func rows(of entry: PlaygroundEntry, at index: Int, expanded: Set<String>) -> [Row] {
        func row(_ part: String, _ kind: Row.Kind) -> Row { Row(id: "\(index).\(part)", entry: index, kind: kind) }
        switch entry {
        case .prompt(let text):
            return [row("main", .prompt(text))]
        case .reply(let markdown):
            return [row("main", .reply(markdown))]
        case .run(let id, let line, let items, let waiting):
            let single = items.count == 1
            let isOpen = !single && expanded.contains(id)
            var rows = [
                row(
                    "main",
                    .work(
                        .init(
                            line: single ? items[0] : line, level: .line,
                            action: single ? .open("\(id).0") : .toggle(id, expanded: isOpen), origin: nil,
                            isSelected: false, flashes: false)))
            ]
            if isOpen {
                rows += items.enumerated().map { number, item in
                    row(
                        "item\(number)",
                        .work(
                            .init(
                                line: item, level: .item, action: .open("\(id).\(number)"), origin: nil,
                                isSelected: false, flashes: false)))
                }
            }
            if let waiting { rows.append(row("approval", .approval(waiting))) }
            return rows
        }
    }

    /// Opens or closes run `id` in place, its line holding still, as the
    /// app's `setDisclosure` does.
    private func toggle(_ id: String) {
        guard
            let index = entries.firstIndex(where: {
                if case .run(let runID, _, _, _) = $0 { runID == id } else { false }
            }),
            let first = rows.firstIndex(where: { $0.entry == index })
        else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        let end = rows[first...].firstIndex { $0.entry != index } ?? rows.endIndex
        let replacement = Self.rows(of: entries[index], at: index, expanded: expanded)
        rows.replaceSubrange(first..<end, with: replacement)
        transcript.performBatchUpdates(anchoring: .row(first)) {
            if end - first > 1 {
                transcript.removeRows(at: IndexSet(first + 1..<end), withAnimation: .effectGap)
            }
            if replacement.count > 1 {
                transcript.insertRows(
                    at: IndexSet(first + 1..<first + replacement.count), withAnimation: .effectGap)
            }
            transcript.reloadRows(at: IndexSet(integer: first))
        }
    }
}

extension PlaygroundTranscript: TranscriptViewDataSource {
    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        rows.count
    }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        let content: TranscriptRowContent =
            switch rows[row].kind {
            case .prompt(let text): .userMessage(TranscriptRowContent.UserMessage(text))
            case .reply(let markdown): .markdown(markdown)
            case .work, .approval: .view
            }
        return TranscriptRow(id: rows[row].id, content: content)
    }
}

extension PlaygroundTranscript: TranscriptViewDelegate {
    func transcriptView(_ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        switch rows[row].kind {
        case .prompt, .reply: preconditionFailure("TranscriptKit measures its own rows")
        case .work(let model): WorkLineRowView.height(for: model, width: width)
        case .approval(let approval): ApprovalCardView.height(for: approval, width: width)
        }
    }

    /// `PageRow.spacingAbove(after:)`: what a line discloses sits flush under
    /// it, an approval card 6 under its run; between entries the transcript's
    /// gap, less the air a line of work holds on either side.
    func transcriptView(_ transcriptView: TranscriptView, customSpacingAboveRow row: Int) -> CGFloat? {
        let this = rows[row]
        if case .work(let model) = this.kind, model.level == .item { return 0 }
        if case .approval = this.kind { return 6 }
        let air = this.air + (row > 0 ? rows[row - 1].air : 0)
        return air == 0 ? nil : TranscriptView.rowSpacing - air
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        func view<V: PageRowView>(_: V.Type, _ model: V.Model) -> V {
            let view = transcriptView.makeView(withIdentifier: V.reuseIdentifier) { V() }
            view.delegate = self
            view.configure(with: model)
            return view
        }
        switch rows[row].kind {
        case .prompt, .reply: preconditionFailure("TranscriptKit draws its own rows")
        case .work(let model): return view(WorkLineRowView.self, model)
        case .approval(let approval): return view(ApprovalCardView.self, approval)
        }
    }

    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int) {}
}

extension PlaygroundTranscript: PageRowViewDelegate {
    /// The page has no editor beside it to open a document in.
    func pageRowView(_ rowView: NSView, didRequestDocument id: String, pinned: Bool) {}

    func pageRowView(_ rowView: NSView, didToggleDisclosureOf runID: String, inAllRuns all: Bool) {
        toggle(runID)
    }

    func pageRowView(_ rowView: NSView, didRequestAllItemsOf runID: String) {}
    func pageRowView(_ rowView: NSView, didRequestOriginOf callID: String) {}
    func pageRowView(_ rowView: NSView, didDecide decision: Decision, forCall callID: String) {}
}

/// The transcript's root: lays out again when its container changes its safe
/// area, which AppKit doesn't do on its own (the app's `SafeAreaView`).
private final class SafeAreaView: NSView {
    override var additionalSafeAreaInsets: NSEdgeInsets {
        didSet { needsLayout = true }
    }
}
