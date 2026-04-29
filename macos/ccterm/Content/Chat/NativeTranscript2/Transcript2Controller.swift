import AppKit

/// Identifies the user bubble whose full text should be shown in a SwiftUI
/// modal sheet. `id` is the originating block's id; `text` is the
/// untruncated source. `Identifiable` so SwiftUI's `.sheet(item:)`
/// resolves presentation identity from this value alone.
struct UserBubbleSheetRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
}

/// Public, imperative API for `NativeTranscript2`. Three orthogonal channels:
///
/// 1. **Mutation** — `apply(_:scroll:)` accepts one or more `Change` values
///    (insert / remove / update) and a `ScrollState`. Granular only; no
///    diff, no `reloadData` escape hatch.
/// 2. **First-screen load** — `loadInitial(_:anchor:)` is the dedicated
///    cold-load path. Splits into a viewport-covering Phase 1 (sync, main)
///    and a Phase 2 (off-main layout, main-hop insert) so 10k-row initial
///    loads don't block the main thread.
/// 3. **Query** — read-only snapshot accessors.
///
/// `@MainActor`-isolated. Background producers must hop before calling.
@MainActor
@Observable
final class Transcript2Controller {
    enum Change: Sendable {
        /// Insert `blocks` after the block with id `after`. `after: nil`
        /// prepends (index 0). If `after` is non-nil but unknown (e.g. the
        /// anchor was removed), the change is a no-op — same posture as
        /// `.update` / `.remove` for unknown ids. To append, pass the
        /// current last block's id (or `nil` if empty).
        case insert(after: UUID?, _ blocks: [Block])
        /// Remove every block whose id is in `ids`. Unknown ids are ignored.
        case remove(ids: [UUID])
        /// Replace the kind of an existing block, preserving its id. No-op
        /// if the id is unknown.
        case update(id: UUID, kind: Block.Kind)
    }

    /// What the table should do with scroll position around an `apply`.
    enum ScrollState: Sendable, Equatable {
        case none
        /// After applying, scroll so the row with `id` is at the visual top.
        case top(id: UUID)
        /// After applying, scroll so the row with `id` is at the visual bottom.
        case bottom(id: UUID)
        /// Capture an anchor row's screen position before the change,
        /// recompute scroll afterwards so the same row stays visually in
        /// place. `Side` picks which row in the visible range to anchor on.
        case saveVisible(Side)

        enum Side: Sendable {
            case visualTop
            case visualBottom
        }
    }

    /// Where to land scroll on first-screen load.
    enum InitialAnchor: Sendable, Equatable {
        /// Default for chat: last block pinned to visual bottom.
        case bottom
        /// Pin the block with `id` to the visual top (jump to message /
        /// unread marker).
        case top(id: UUID)
        /// Pin the block with `id` to the visual bottom.
        case bottomTo(id: UUID)
    }

    /// Mirrored from the coordinator after every mutation so SwiftUI can
    /// observe count changes without reaching into AppKit state.
    private(set) var blockCount: Int = 0

    /// Pending request for the SwiftUI "show full user message" sheet,
    /// driven by chevron clicks inside `BlockCellView`. NSView-internal
    /// interactions (link click, selection drag, chevron tap) are normally
    /// AppKit-closed-loop; this is the one well-defined exit point because
    /// `.sheet(item:)` is a SwiftUI presentation primitive and has to live
    /// on the SwiftUI side. `NativeTranscript2View` binds against this
    /// field and clears it on dismiss.
    var pendingUserBubbleSheet: UserBubbleSheetRequest?

    /// Module-internal: handed to `NativeTranscript2View.makeCoordinator`.
    let coordinator: Transcript2Coordinator

    init() {
        coordinator = Transcript2Coordinator()
        coordinator.onBlockCountChanged = { [weak self] count in
            self?.blockCount = count
        }
        coordinator.onUserBubbleSheetRequested = { [weak self] id, text in
            self?.pendingUserBubbleSheet = UserBubbleSheetRequest(id: id, text: text)
        }
    }

    // MARK: - Mutation

    /// Sync apply: layouts compute lazily on `heightOfRow` queries. Use for
    /// incremental updates (single message arrives, tool result fills in,
    /// user deletes one).
    func apply(_ changes: Change..., scroll: ScrollState = .none) {
        coordinator.apply(changes, scroll: scroll)
    }

    // MARK: - First-screen load

    /// Two-phase initial load. Phase 1 (sync) inserts a viewport-covering
    /// slice so the user sees correct content immediately. Phase 2 (off-main
    /// layout, main-hop insert) installs the rest with `.saveVisible` to
    /// keep Phase 1 visually fixed.
    ///
    /// The vertical scroller is push-hidden across both phases — Phase 1's
    /// scroll-to-anchor and Phase 2's insert+saveVisible both perturb the
    /// scroll origin, and the overlay scroller's auto-flash on
    /// `contentSize` change would otherwise paint a bouncing knob across
    /// the cold-load. Popped after Phase 1 (no-Phase-2 branch) or from
    /// Phase 2's completion (which `applyInBackground` guarantees to fire).
    func loadInitial(_ blocks: [Block], anchor: InitialAnchor = .bottom) {
        guard !blocks.isEmpty else { return }

        let width = coordinator.layoutWidth
        let viewportHeight = coordinator.viewportHeight
        guard width > 0, viewportHeight > 0 else {
            // Table not attached or zero-sized. Stash blocks; future attach
            // triggers reloadData. Scroll is meaningless without a table —
            // and so is the scroller-hidden token.
            coordinator.apply([.insert(after: coordinator.blockIds.last, blocks)], scroll: .none)
            return
        }

        let slice = Self.sliceForViewport(
            blocks: blocks, anchor: anchor,
            width: width, viewportHeight: viewportHeight)

        let phase1Scroll: ScrollState
        let phase2Side: ScrollState.Side
        switch anchor {
        case .bottom:
            phase1Scroll = .bottom(id: blocks[slice.viewportRange.upperBound - 1].id)
            phase2Side = .visualBottom
        case .top(let id):
            phase1Scroll = .top(id: id)
            phase2Side = .visualTop
        case .bottomTo(let id):
            phase1Scroll = .bottom(id: id)
            phase2Side = .visualBottom
        }

        let viewportBatch = Array(blocks[slice.viewportRange])
        let above = Array(blocks[..<slice.viewportRange.lowerBound])
        let below =
            slice.viewportRange.upperBound < blocks.count
            ? Array(blocks[slice.viewportRange.upperBound...])
            : []

        coordinator.pushScrollerHidden()

        // Phase 1 — viewport batch, sync. heightOfRow lazy-computes layouts
        // for the visible rows; cost is bounded by viewport size.
        coordinator.apply(
            [.insert(after: coordinator.blockIds.last, viewportBatch)],
            scroll: phase1Scroll)

        // Phase 2 — the rest, off-main layout. ID-based anchors mean
        // ordering between the two inserts no longer matters: each anchor
        // resolves at apply-time independently of the other change.
        var phase2: [Change] = []
        if !below.isEmpty {
            phase2.append(.insert(after: viewportBatch.last?.id, below))
        }
        if !above.isEmpty {
            phase2.append(.insert(after: nil, above))
        }
        if phase2.isEmpty {
            coordinator.popScrollerHidden()
        } else {
            coordinator.applyInBackground(phase2, scroll: .saveVisible(phase2Side)) {
                [weak coordinator] in coordinator?.popScrollerHidden()
            }
        }
    }

    // MARK: - Query

    var blockIds: [UUID] { coordinator.blockIds }

    // MARK: - Slicing (private)

    private struct Slice {
        /// Range into the original `blocks` array covering the viewport.
        let viewportRange: Range<Int>
    }

    /// Walks `blocks` from the anchor outward, accumulating row heights
    /// until viewport is covered. Pure: only reads `Coordinator.makeLayout`
    /// (a `nonisolated static` function); does not mutate cache.
    private static func sliceForViewport(
        blocks: [Block],
        anchor: InitialAnchor,
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> Slice {
        func rowHeight(_ block: Block) -> CGFloat {
            let pad = BlockStyle.blockPadding(for: block.kind)
            return Transcript2Coordinator.makeLayout(for: block, width: width).totalHeight
                + pad.top + pad.bottom
        }

        switch anchor {
        case .bottom:
            var height: CGFloat = 0
            var first = blocks.count
            for i in stride(from: blocks.count - 1, through: 0, by: -1) {
                height += rowHeight(blocks[i])
                first = i
                if height >= viewportHeight { break }
            }
            return Slice(viewportRange: first..<blocks.count)

        case .top(let id):
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == id }) else {
                return sliceForViewport(
                    blocks: blocks, anchor: .bottom,
                    width: width, viewportHeight: viewportHeight)
            }
            var height: CGFloat = 0
            var last = anchorIdx
            for i in anchorIdx..<blocks.count {
                height += rowHeight(blocks[i])
                last = i
                if height >= viewportHeight { break }
            }
            return Slice(viewportRange: anchorIdx..<last + 1)

        case .bottomTo(let id):
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == id }) else {
                return sliceForViewport(
                    blocks: blocks, anchor: .bottom,
                    width: width, viewportHeight: viewportHeight)
            }
            var height: CGFloat = 0
            var first = anchorIdx
            for i in stride(from: anchorIdx, through: 0, by: -1) {
                height += rowHeight(blocks[i])
                first = i
                if height >= viewportHeight { break }
            }
            return Slice(viewportRange: first..<anchorIdx + 1)
        }
    }
}
