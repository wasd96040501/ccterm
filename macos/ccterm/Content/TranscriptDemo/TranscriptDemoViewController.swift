import AppKit
import SwiftUI

/// AppKit-rooted host for the transcript content demo. Replaces the
/// former SwiftUI `TranscriptDemoView`: this VC is now the side-branch
/// payload `TranscriptDetailViewController` mounts when the user picks
/// the "Transcript Demo" sidebar item. The transcript itself goes
/// through the canonical attach pattern (see
/// `TranscriptScrollViewFactory` doc-comment + `CLAUDE.md`'s
/// runloop-tick model) — make an unbound scroll shell, mount it,
/// `layoutSubtreeIfNeeded` to settle the geometry, then `bindData` —
/// so the first row tile lands at the final settled width and every
/// block is typeset exactly once. The bottom control panel is still
/// SwiftUI, hosted via `NSHostingView`.
///
/// Sheets (`UserBubbleSheetView` / `ImagePreviewSheetView`) are now
/// presented via `Transcript2SheetPresenter` against the host's
/// `view.window`; no SwiftUI `.sheet(item:)` involvement.
@MainActor
final class TranscriptDemoViewController: NSViewController {

    /// Snapshot test seam — pre-seed the controller before
    /// constructing the VC and pass it in here. Default `nil` allocates
    /// a fresh one, matching the production demo path where the
    /// `viewDidLoad` seed closure populates it.
    init(
        controller: Transcript2Controller? = nil,
        syntaxEngine: SyntaxHighlightEngine? = nil
    ) {
        self.controller = controller ?? Transcript2Controller()
        self.syntaxEngine = syntaxEngine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    let controller: Transcript2Controller
    private let syntaxEngine: SyntaxHighlightEngine?
    private var scroll: Transcript2ScrollView?
    private var sheetPresenter: Transcript2SheetPresenter?
    private var controlPanelHost: NSHostingView<TranscriptDemoControlPanel>?
    /// Monotonic counter for extra-pool cycling. Decoupled from
    /// `blockCount` so deletions don't reset the cycle (which would
    /// otherwise pin every appended block to `extraPool[0]` once the
    /// live count dropped below `initialBlocks.count`).
    private var extraAddCount: Int = 0

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mountTranscript()
        installControlPanel()
        installSheetPresenter()
        seedInitialStateIfNeeded()
        if let syntaxEngine {
            controller.attachSyntaxEngine(syntaxEngine)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sheetPresenter?.stop()
    }

    deinit {
        if let scroll {
            // Cannot call MainActor-isolated dismantle from a
            // nonisolated deinit; the observation removal would
            // happen on the wrong actor. Safe to leak: when the
            // controller goes away its coordinator goes with it and
            // the notification center's weak observer drops. The
            // explicit cleanup in `viewWillDisappear` is the primary
            // path.
            _ = scroll
        }
    }

    private func mountTranscript() {
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Settle scroll geometry before binding the dataSource so the
        // first `heightOfRow` query lands at the final width. See
        // TranscriptScrollViewFactory's doc-comment for the contract.
        view.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        controller.scrollToTail()
        self.scroll = scroll
    }

    private func installSheetPresenter() {
        sheetPresenter = Transcript2SheetPresenter(controller: controller, hostView: view)
    }

    private func installControlPanel() {
        let panel = TranscriptDemoControlPanel(
            controller: controller,
            onAddMessage: { [weak self] in self?.handleAddMessage() },
            onRemoveMessage: { [weak self] in self?.handleRemoveMessage() },
            onToggleStatus: { [weak self] next in self?.handleToggleStatus(next) }
        )
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        controlPanelHost = host
    }

    // MARK: - Seed

    private func seedInitialStateIfNeeded() {
        // Idempotent — a pre-seeded controller (snapshot test path)
        // skips this. Same guard the old SwiftUI `.task` carried.
        guard controller.blockCount == 0 else { return }
        controller.apply(.append(Self.initialBlocks))
        // Mark the third toolGroup live. Status flows through the
        // dedicated `setToolStatus` channel so the rows already in the
        // table refresh granularly. Mixed per-child statuses prove
        // sibling rendering stays independent: only the bash row
        // picks up the running palette + progressive label.
        controller.setToolStatus(id: Self.runningGroupBlockId, status: .running)
        controller.setToolStatus(id: Self.runningReadChildId, status: .completed)
        controller.setToolStatus(id: Self.runningGrepChildId, status: .completed)
        controller.setToolStatus(id: Self.runningBashChildId, status: .running)
    }

    // MARK: - Control panel callbacks

    private func handleAddMessage() {
        let next = Self.extraBlock(at: extraAddCount)
        controller.apply(.insert(after: controller.blockIds.last, [next]))
        extraAddCount += 1
    }

    private func handleRemoveMessage() {
        guard controller.blockCount > 1, let lastId = controller.blockIds.last else { return }
        controller.apply(.remove(ids: [lastId]))
    }

    private func handleToggleStatus(_ next: ToolStatus) {
        controller.setToolStatus(id: Self.runningGroupBlockId, status: next)
        controller.setToolStatus(id: Self.runningBashChildId, status: next)
    }
}

// MARK: - Control panel (SwiftUI)

/// The floating control bar that sits below the transcript. Pulled out
/// of the VC because `NSHostingView`'s rootView is a generic `View`
/// type — keeping the SwiftUI surface in a named struct makes the
/// hosting type explicit and keeps `@State` (the local
/// `runningGroupStatus` flip) inside SwiftUI's own state graph.
struct TranscriptDemoControlPanel: View {
    @Bindable var controller: Transcript2Controller
    let onAddMessage: () -> Void
    let onRemoveMessage: () -> Void
    let onToggleStatus: (ToolStatus) -> Void
    @State private var runningGroupStatus: ToolStatus = .running

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAddMessage) {
                Label("Add Message", systemImage: "plus.circle.fill")
            }
            Button(action: onRemoveMessage) {
                Label("Remove Message", systemImage: "minus.circle.fill")
            }
            .disabled(controller.blockCount <= 1)

            Divider().frame(height: 16)

            Button {
                let next: ToolStatus =
                    (runningGroupStatus == .running) ? .completed : .running
                runningGroupStatus = next
                onToggleStatus(next)
            } label: {
                Label(
                    runningGroupStatus == .running ? "Mark Completed" : "Mark Running",
                    systemImage: "wand.and.stars")
            }

            Divider().frame(height: 16)

            Text("\(controller.blockCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}
