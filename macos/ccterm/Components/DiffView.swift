import AppKit
import SwiftUI

/// Reusable diff card extracted from the transcript's `fileEdit` body.
///
/// Renders a `DiffBlock` as a rounded `codeBlock`-style card via
/// `DiffLayout` and adds text selection (drag / double-click word /
/// triple-click all / ⌘A / ⌘C / right-click Copy) plus async per-line
/// syntax highlighting through `\.syntaxEngine`. No file-path header, no
/// chevron, no fold state, no search highlights — just the card.
///
/// **Independence from the transcript runtime.** Highlight plumbing is
/// local: the view runs the same `FileEditChildHighlight`-style pass
/// (per-unique-line `engine.highlightBatch`) inside its own `.task`, and
/// stores the resulting `lineMap` in local `@State`. Selection state lives
/// inside the backing `DiffNSView`. Neither `Transcript2HighlightStorage`
/// nor `Transcript2SelectionCoordinator` is involved, so the view drops
/// into any SwiftUI hierarchy.
///
/// Width-flexible, height-intrinsic: `sizeThatFits` reports the height
/// `DiffLayout` produces for the proposed width.
struct DiffView: View {
    let diff: DiffBlock

    @Environment(\.syntaxEngine) private var engine
    @State private var lineMap: [String: [SyntaxToken]]?

    var body: some View {
        DiffViewBridge(diff: diff, lineMap: lineMap)
            .task(id: HighlightInput(diff: diff, hasEngine: engine != nil)) {
                lineMap = nil
                await runHighlight()
            }
    }

    private func runHighlight() async {
        guard let engine else { return }
        let lang = LanguageDetection.language(for: diff.filePath)
        var seen = Set<String>()
        var unique: [String] = []
        for line in diff.lines where !line.isEmpty {
            if seen.insert(line).inserted { unique.append(line) }
        }
        guard !unique.isEmpty else { return }
        let payload = unique.map { ($0, lang) }
        let results = await engine.highlightBatch(payload)
        // `.task(id:)` cancels the prior task on input change, but the
        // already-issued `highlightBatch` runs to completion on the actor.
        // Drop the writeback on cancellation so a stale highlight can't
        // overtake the new one.
        if Task.isCancelled { return }
        var map: [String: [SyntaxToken]] = [:]
        for (content, tokens) in zip(unique, results) {
            map[content] = tokens
        }
        lineMap = map
    }

    private struct HighlightInput: Equatable {
        let diff: DiffBlock
        let hasEngine: Bool
    }
}

// MARK: - Representable

private struct DiffViewBridge: NSViewRepresentable {
    let diff: DiffBlock
    let lineMap: [String: [SyntaxToken]]?

    func makeNSView(context: Context) -> DiffNSView { DiffNSView() }

    func updateNSView(_ nsView: DiffNSView, context: Context) {
        nsView.update(diff: diff, lineMap: lineMap)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DiffNSView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return nil
        }
        return CGSize(width: width, height: nsView.height(at: width))
    }
}

// MARK: - AppKit backing view

/// Self-drawn diff body. Same draw recipe as `BlockCellView` for diff
/// bodies (backplate → selection band → glyphs) but trimmed to a single
/// block: no row indirection, no controller, no fold / search overlay.
final class DiffNSView: NSView, NSUserInterfaceValidations {
    private var diff: DiffBlock?
    private var lineMap: [String: [SyntaxToken]]?

    private var cachedLayout: DiffLayout?
    private var cachedWidth: CGFloat = -1

    private var anchorChar: Int?
    private var cursorChar: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Cache the CG-drawn bitmap; only redraw on explicit needsDisplay.
        // Same posture as transcript cells — selection drag and key-window
        // flips become bitmap composites, not glyph re-typeset passes.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - SwiftUI-driven update

    func update(diff: DiffBlock, lineMap: [String: [SyntaxToken]]?) {
        let diffChanged = self.diff != diff
        let lineMapChanged = !sameLineMap(self.lineMap, lineMap)
        guard diffChanged || lineMapChanged else { return }
        if diffChanged {
            anchorChar = nil
            cursorChar = nil
        }
        self.diff = diff
        self.lineMap = lineMap
        invalidateLayoutCache()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Cheap check covering the only realistic transitions: `nil ↔ some`
    /// (highlight arrives or diff resets) and `some(a) → some(b)` where
    /// `a` and `b` may carry different unique-line counts. Same-count
    /// non-identical maps are not produced by the current pipeline (the
    /// only producer is `runHighlight`, which writes once per diff).
    private func sameLineMap(
        _ a: [String: [SyntaxToken]]?,
        _ b: [String: [SyntaxToken]]?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (.some(let l), .some(let r)): return l.count == r.count
        default: return false
        }
    }

    // MARK: - Layout

    private func invalidateLayoutCache() {
        cachedLayout = nil
        cachedWidth = -1
    }

    private func layout(at width: CGFloat) -> DiffLayout? {
        guard let diff else { return nil }
        if let cachedLayout, cachedWidth == width { return cachedLayout }
        let made = DiffLayout.make(
            diff: diff,
            lineMap: lineMap,
            originX: 0,
            originY: 0,
            maxWidth: max(0, width))
        cachedLayout = made
        cachedWidth = width
        return made
    }

    func height(at width: CGFloat) -> CGFloat {
        layout(at: width)?.totalHeight ?? 0
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        // Don't invalidate explicitly — `layout(at:)` keys on width and
        // rebuilds on miss. `sizeThatFits` typically primes the cache for
        // the same width SwiftUI then assigns here, so we usually hit.
        if widthChanged { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        if let cachedLayout, cachedWidth == bounds.width {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: cachedLayout.totalHeight)
        }
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
            let layout = layout(at: bounds.width)
        else { return }
        let origin = CGPoint.zero
        layout.drawBackplate(in: ctx, origin: origin)
        if let lo = selectionLo, let hi = selectionHi, lo < hi {
            let color: NSColor =
                (window?.isKeyWindow == true)
                ? .selectedTextBackgroundColor
                : .unemphasizedSelectedTextBackgroundColor
            ctx.setFillColor(color.cgColor)
            for rect in layout.rects(loChar: lo, hiChar: hi) {
                ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
            }
        }
        layout.draw(in: ctx, origin: origin)
    }

    // MARK: - Selection state

    private var selectionLo: Int? {
        guard let a = anchorChar, let c = cursorChar, a != c else { return nil }
        return min(a, c)
    }

    private var selectionHi: Int? {
        guard let a = anchorChar, let c = cursorChar, a != c else { return nil }
        return max(a, c)
    }

    private var hasSelection: Bool { selectionLo != nil }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let layout = layout(at: bounds.width) else { return }
        let local = convert(event.locationInWindow, from: nil)
        switch event.clickCount {
        case 1:
            let char = layout.hitTest(point: local)
            anchorChar = char
            cursorChar = char
        case 2:
            let char = layout.hitTest(point: local)
            if let word = layout.wordBoundary(at: char) {
                anchorChar = word.location
                cursorChar = word.location + word.length
            } else {
                anchorChar = char
                cursorChar = char
            }
        default:
            anchorChar = 0
            cursorChar = layout.contentLength
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let layout = layout(at: bounds.width), anchorChar != nil
        else { return }
        let local = convert(event.locationInWindow, from: nil)
        cursorChar = layout.hitTest(point: local)
        autoscroll(with: event)
        needsDisplay = true
    }

    // MARK: - Standard responder actions

    @objc func copy(_ sender: Any?) {
        guard let layout = cachedLayout,
            let lo = selectionLo, let hi = selectionHi
        else { return }
        let text = layout.string(loChar: lo, hiChar: hi)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let layout = layout(at: bounds.width),
            layout.contentLength > 0
        else { return }
        anchorChar = 0
        cursorChar = layout.contentLength
        needsDisplay = true
    }

    func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(selectAll(_:)):
            return (cachedLayout?.contentLength ?? 0) > 0
        default:
            return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard hasSelection else { return nil }
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Copy"),
            action: #selector(copy(_:)),
            keyEquivalent: "")
        return menu
    }

    // MARK: - Key window state

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        center.addObserver(
            self, selector: #selector(keyWindowDidChange),
            name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(
            self, selector: #selector(keyWindowDidChange),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func keyWindowDidChange() {
        if hasSelection { needsDisplay = true }
    }
}

// MARK: - Preview

private struct DiffViewPreview: View {
    @Environment(\.syntaxEngine) private var engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section(title: "Edit — Swift", diff: editDiff)
                section(title: "New file — Swift", diff: newFileDiff)
                section(title: "Edit — Markdown", diff: markdownDiff)
                section(title: "Empty diff", diff: emptyDiff)
            }
            .padding(20)
        }
        .task {
            // Warm the JS engine up front so the previewed cards pick
            // up tokens on first paint. Mirrors AppState's eager load.
            await engine?.load()
        }
    }

    @ViewBuilder
    private func section(title: String, diff: DiffBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            DiffView(diff: diff)
        }
    }

    private var editDiff: DiffBlock {
        DiffBlock(
            filePath: "Sources/Greeter.swift",
            oldString: """
                import Foundation

                struct Greeter {
                    let name: String

                    func greet() -> String {
                        return "Hello, " + name
                    }
                }
                """,
            newString: """
                import Foundation

                struct Greeter {
                    let name: String
                    let formal: Bool

                    func greet() -> String {
                        let prefix = formal ? "Good day, " : "Hello, "
                        return prefix + name + "!"
                    }
                }
                """)
    }

    private var newFileDiff: DiffBlock {
        DiffBlock(
            filePath: "Sources/HelloWorld.swift",
            oldString: nil,
            newString: """
                import Foundation

                @main
                struct HelloWorld {
                    static func main() {
                        print("Hello, world!")
                    }
                }
                """)
    }

    private var markdownDiff: DiffBlock {
        DiffBlock(
            filePath: "README.md",
            oldString: "# Project\n\nLegacy intro.\n",
            newString: "# Project\n\nNew description.\nMore details on usage.\n")
    }

    private var emptyDiff: DiffBlock {
        DiffBlock(
            filePath: "Sources/Unchanged.swift",
            oldString: "let x = 1\n",
            newString: "let x = 1\n")
    }
}

#Preview("DiffView") {
    DiffViewPreview()
        .frame(width: 680, height: 720)
        .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
