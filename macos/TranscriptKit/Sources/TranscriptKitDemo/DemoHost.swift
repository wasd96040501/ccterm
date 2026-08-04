import AppKit
import TranscriptKit

/// Data source and delegate for the demo: the script in `DemoMessage.swift`,
/// plus the mutations the control panel drives.
///
/// Every mutation is the same two lines a real host writes — change the model,
/// then announce the change — and each announcement is deliberately the
/// index-based one rather than `reloadData()`, since that is what scroll
/// anchoring applies to.
@MainActor
final class DemoHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private var messages: [DemoMessage] = DemoMessage.script
    private var mutationCount = 0

    weak var transcript: TranscriptView?
    var onRowCountChange: ((Int) -> Void)?

    // MARK: - Mutations

    /// Above the viewport, wherever the viewport is: the case where holding the
    /// content still is the whole point.
    func prepend(_ count: Int) {
        let inserted = (0..<count).map { index in
            DemoMessage(author: .assistant, text: label("▲ prepended", index))
        }
        messages.insert(contentsOf: inserted, at: 0)
        transcript?.insertRows(at: IndexSet(0..<count))
        reportRowCount()
    }

    /// Below everything: the case where the answer depends on where the reader is
    /// — at the end it follows, anywhere else it doesn't move.
    func append() {
        messages.append(DemoMessage(author: .user, text: label("▼ appended", 0)))
        transcript?.insertRows(at: IndexSet(integer: messages.count - 1))
        reportRowCount()
    }

    func removeTop(_ count: Int) {
        let removed = min(count, messages.count)
        guard removed > 0 else { return }
        messages.removeFirst(removed)
        transcript?.removeRows(at: IndexSet(0..<removed))
        reportRowCount()
    }

    /// A row above the viewport changing height without changing identity — the
    /// mutation that has no index set to shift, only geometry to compensate for.
    func growFirstRow() {
        guard !messages.isEmpty else { return }
        let grown = String(repeating: "This row keeps growing. ", count: 6)
        messages[0] = DemoMessage(
            author: messages[0].author, text: "\(messages[0].text) \(grown)")
        transcript?.reloadRows(at: IndexSet(integer: 0))
    }

    /// The same height change announced without re-rendering the row: the other
    /// public path to it, and the one a hosted view uses when it grows itself.
    func remeasureFirstRow() {
        guard !messages.isEmpty else { return }
        let grown = String(repeating: "Re-measured, not re-rendered. ", count: 4)
        messages[0] = DemoMessage(
            author: messages[0].author, text: "\(messages[0].text) \(grown)")
        transcript?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
    }

    /// Two mutations, one anchor: five rows in at the top and three out from just
    /// below them, so the renumbering has to compose across the group.
    func prependAndRemoveInOneBatch() {
        // The removal is expressed in post-insert indices, so it needs three
        // rows to exist below the five going in.
        guard messages.count >= 8 else { return }
        transcript?.beginUpdates()
        prepend(5)
        messages.removeSubrange(10..<13)
        transcript?.removeRows(at: IndexSet(10..<13))
        transcript?.endUpdates()
        reportRowCount()
    }

    private func label(_ prefix: String, _ index: Int) -> String {
        mutationCount += 1
        return "\(prefix) #\(mutationCount).\(index) — watch whether this pushed the text you "
            + "were reading off its line."
    }

    private func reportRowCount() {
        onRowCountChange?(messages.count)
    }

    // MARK: - Data source and delegate

    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        messages.count
    }

    /// Every row is the transcript's to draw — an assistant turn as a markdown
    /// document, a user turn as a bubble. The demo owns no row views at all, and
    /// therefore implements neither `heightOfRow` nor `viewForRow`: their default
    /// implementations trap, and a host that never answers `.view` never reaches
    /// them.
    ///
    /// That both row kinds share one recycling pool is still a real failure mode;
    /// it is asserted in `UserMessageRowTests` rather than watched here, because
    /// what it looks like when it goes wrong is a row rendering another row's
    /// content — which a test can see as readily as an eye can.
    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent {
        switch messages[row].author {
        case .assistant: return .markdown(messages[row].text)
        case .user: return .userMessage(messages[row].text)
        }
    }

    // MARK: - Links

    /// Opening it is the host's too, and this is the whole of what that takes.
    ///
    /// Guarded on a scheme because a document's links are not all addresses: the
    /// demo's images point at `block-tree.png` and friends, which are relative
    /// paths to files that do not exist. Handing one of those to the workspace
    /// asks it to open something relative to nothing. A real host would resolve
    /// them against wherever the document came from.
    func transcriptView(
        _ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int
    ) {
        guard url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }

    /// Where a link goes, shown while the pointer is on it.
    ///
    /// The whole of what the transcript does here is *say which link* — this is
    /// the host deciding to draw a label for it, and the demo exists partly to
    /// show that the decision is the host's. An app might put the address in a
    /// status bar, or nothing at all.
    ///
    /// The hover is reported on change only, so this is one call per link rather
    /// than one per mouse-moved event, and `hide()` needs no state kept here.
    func transcriptView(
        _ transcriptView: TranscriptView, didHover url: URL?, at point: NSPoint, inRow row: Int
    ) {
        guard let url else { return tooltip.hide() }
        let text = url.absoluteString
        tooltip.show(text.removingPercentEncoding ?? text, at: point, in: transcriptView)
    }

    private let tooltip = LinkTooltip()

    // MARK: - The context menu
    //
    // Deliberately not implemented. `transcriptView(_:menu:forRow:)` is where a
    // host appends its own items — Quote, Retry, Copy as Markdown — and the
    // default implementation returns the transcript's menu unchanged, so what
    // the demo shows is what a host that has not thought about menus yet gets:
    // the transcript's own Copy, and nothing else.
    //
    // Nothing is lost by leaving it out. The hook's behaviour — that the host is
    // asked about the row it clicked, that its answer is what gets shown, that
    // returning `nil` suppresses the menu — is assertable, and `ContextMenuTests`
    // asserts it. The demo carries what tests cannot reach (§5), and a menu item
    // that prints to stdout is not that.
}
