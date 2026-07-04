import AppKit
import Combine

/// AppKit transcript for a single session — reads a `TranscriptStore`
/// pulled from the app-scope `TranscriptRegistryStore`. Session-agnostic:
/// the only session-bound thing it holds is the store, which is opaquely
/// keyed by transcript id.
///
/// **Data flow.** VC is a pure read-side reader:
///
/// - `store.blocks` drives `numberOfRows` + row indexing.
/// - `store.layout(for:width:)` drives `heightOfRow` + `viewFor` — the
///   cell view configures itself off the returned `T3RowLayout`. Cache
///   miss → Store typesets sync inline; cache hit → O(1) lookup.
/// - `store.events` drives `apply(_:)` — the incremental writer path.
///
/// **Phase 1 vs Phase 2.** Tail batch (the newest slice, first-frame
/// critical) runs the whole make + writeLayouts + insertRows chain
/// synchronously on the main thread — first-frame determinism beats
/// responsiveness on the first paint. Older batches run their typeset
/// on `Task.detached`, then hop back to the main actor for the batch
/// `writeLayouts` + `insertRows` — the main thread only pays ~5ms per
/// batch after that.
///
/// **Lifecycle.** VC dies on sidebar switch-away; the store it references
/// stays put in the app-scope registry. On switch-back, a fresh VC
/// re-attaches to the same store — `store.blocks` non-empty short-circuits
/// the loader, and `store.layouts` are still populated so heightOfRow /
/// viewFor bypass every typeset call. That's the "instant switch-back"
/// property the architecture buys us.
@MainActor
final class TranscriptViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, DetailContainerChild
{

    private let store: TranscriptStore

    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var bag: Set<AnyCancellable> = []

    init(store: TranscriptStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - View tree

    override func loadView() {
        let host = NSView()
        host.wantsLayer = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.rowSizeStyle = .custom

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        col.resizingMask = [.autoresizingMask]
        table.addTableColumn(col)

        scroll.documentView = table
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        self.scrollView = scroll
        self.tableView = table
        self.view = host
    }

    // MARK: - Bindings

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self

        store.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] delta in self?.apply(delta) }
            .store(in: &bag)

        // Cache warm from a prior mount: switch-back re-attaches to a
        // store whose blocks + layouts are already populated. Skip loader
        // and paint immediately.
        if !store.blocks.isEmpty {
            tableView.reloadData()
            tableView.scrollRowToVisible(store.blocks.count - 1)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        store.loadHistoryIfNeeded()
    }

    // MARK: - DetailContainerChild

    func prepareForRemoval() {
        bag.removeAll()
        tableView.dataSource = nil
        tableView.delegate = nil
        // Deliberately no cancel on the store's loader — it lives past us
        // in the registry, and letting it finish means the next mount
        // pays zero SDK cost.
    }

    // MARK: - Phase 1 / Phase 2 apply

    private var contentWidth: CGFloat {
        max(tableView.bounds.width, 320)
    }

    private func apply(_ delta: TranscriptStore.BlockDelta) {
        let w = contentWidth
        switch delta {

        case .tail(let blocks):
            // Phase 1 — sync typeset + writeLayouts + insertRows in the
            // same runloop tick. Main-thread hit is real (~100-200ms for
            // 20 rows) but first-frame determinism is worth it.
            var pairs: [(T3Block.ID, T3RowLayout)] = []
            pairs.reserveCapacity(blocks.count)
            for b in blocks {
                pairs.append((b.id, T3RowLayout.make(for: b, width: w)))
            }
            store.writeLayouts(pairs, width: w)
            let start = tableView.numberOfRows
            let range = start..<start + blocks.count
            tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
            if tableView.numberOfRows > 0 {
                tableView.scrollRowToVisible(tableView.numberOfRows - 1)
            }

        case .older(let blocks):
            // Phase 2 — off-main typeset via `Task.detached`, then hop
            // back and land the batch on the main actor. The main thread
            // pays only the `writeLayouts` + `insertRows` cost (<5ms).
            let blocksCopy = blocks
            Task.detached(priority: .userInitiated) { [weak self] in
                var pairs: [(T3Block.ID, T3RowLayout)] = []
                pairs.reserveCapacity(blocksCopy.count)
                for b in blocksCopy {
                    pairs.append((b.id, T3RowLayout.make(for: b, width: w)))
                }
                await MainActor.run {
                    guard let self else { return }
                    self.store.writeLayouts(pairs, width: w)
                    self.tableView.insertRows(
                        at: IndexSet(integersIn: 0..<blocksCopy.count),
                        withAnimation: [])
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource + Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.blocks.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        store.layout(for: store.blocks[row], width: contentWidth).height
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let block = store.blocks[row]
        let layout = store.layout(for: block, width: contentWidth)
        let cell =
            tableView.makeView(
                withIdentifier: T3BlockCellView.identifier, owner: nil) as? T3BlockCellView
            ?? T3BlockCellView()
        cell.identifier = T3BlockCellView.identifier
        cell.configure(with: block, layout: layout)
        return cell
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26. `bag` releases with `self` and cancels every
    /// subscription automatically.
    nonisolated deinit {}
}
