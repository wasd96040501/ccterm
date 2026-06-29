import AppKit

/// AppKit replacement for the SwiftUI `UserBubbleSheetView` body that
/// `Transcript2SheetPresenter` hosts (migration plan §4.7). A PLAIN
/// `NSViewController` (NOT an `NSHostingController`): a read-only but
/// **selectable** `NSTextView` showing the full bubble text inside a bounded
/// `NSScrollView`, a divider, and a trailing Done button.
///
/// **Selectable, not editable** — `isEditable = false` + `isSelectable = true`
/// reproduces SwiftUI's `Text(...).textSelection(.enabled)`: the text view
/// becomes first responder for ⌘C copy, but accepts no typing. Because it is
/// not editable there is **no IME marked text** here — none of the
/// `InputNSTextView` composition machinery applies (§4.7-2). Selection / copy
/// come for free from `NSTextView`.
///
/// **Dismissal (§4.7-2/4).** A read-only selectable `NSTextView` becomes first
/// responder and would otherwise swallow Return before the Done button's
/// `\r` keyEquivalent fires. Two guards close this: (a) the Done button is the
/// window's `initialFirstResponder` so Return resolves to it, and (b) the text
/// view forwards `insertNewline(_:)` to `onDismiss`. Esc routes through
/// `cancelOperation(_:)`. All paths flow through the injected `onDismiss`
/// closure — AppKit-presented sheets do NOT propagate the SwiftUI dismiss
/// environment, the same pattern `Transcript2SheetPresenter` already uses.
///
/// `viewWillDisappear` / `viewDidDisappear` are left side-effect-free so a
/// sheet dismissed inside the transcript swap's disabled `CATransaction` does
/// no layout / async work mid-swap (§4.7-4).
@MainActor
final class UserBubbleSheetViewController: NSViewController {

    /// The size envelope handed to the sheet — drives `preferredContentSize`
    /// (ideal) and the window `contentMinSize` / `contentMaxSize` the presenter
    /// reads off it (§4.7-3). Matches the SwiftUI body's
    /// `.frame(minWidth: 520, idealWidth: 720, maxWidth: 960, minHeight: 360,
    /// idealHeight: 540, maxHeight: 800)` (UserBubbleSheetView.swift:29-31).
    struct Envelope: Equatable {
        let minWidth: CGFloat
        let idealWidth: CGFloat
        let maxWidth: CGFloat
        let minHeight: CGFloat
        let idealHeight: CGFloat
        let maxHeight: CGFloat

        /// User-bubble full-text path — `UserBubbleSheetView.swift:29-31`.
        static let userBubble = Envelope(
            minWidth: 520, idealWidth: 720, maxWidth: 960,
            minHeight: 360, idealHeight: 540, maxHeight: 800)
    }

    /// `.padding(20)` around the text (UserBubbleSheetView.swift:19).
    private static let textInset: CGFloat = 20
    /// `.padding(12)` on the Done row (UserBubbleSheetView.swift:27).
    private static let doneRowPadding: CGFloat = 12

    private let text: String
    let envelope: Envelope
    private let onDismiss: () -> Void

    private var textView: ForwardingNewlineTextView!
    private var doneButton: NSButton!

    // MARK: - Init

    /// - Parameters:
    ///   - text: the untruncated bubble source (`UserBubbleSheetRequest.text`).
    ///   - envelope: the size envelope (defaults to the user-bubble envelope).
    ///   - onDismiss: invoked on Done / Return / Esc.
    init(
        text: String,
        envelope: Envelope = .userBubble,
        onDismiss: @escaping () -> Void
    ) {
        self.text = text
        self.envelope = envelope
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: envelope.idealWidth, height: envelope.idealHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        // Bounded scroll view hosting the read-only selectable text view.
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = ForwardingNewlineTextView()
        textView.onNewline = { [weak self] in self?.onDismiss() }
        textView.string = text
        // Read-only but selectable → SwiftUI `.textSelection(.enabled)` + no
        // typing. ⌘C copies; Return / typing never edit.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        // `.font(.body)` (UserBubbleSheetView.swift:16).
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        // `.padding(20)` — the text inset lives on the text container so the
        // selectable glyph area sits 20pt inside the scroll viewport, matching
        // the SwiftUI `.padding(20)` around the `Text`.
        textView.textContainerInset = NSSize(width: Self.textInset, height: Self.textInset)
        // Wrap to the viewport width (left-aligned, `maxWidth: .infinity`
        // leading in SwiftUI) and grow vertically inside the scroll view.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Zero the default 5pt line-fragment pad so the left glyph edge lands
        // at exactly `textInset` (20pt) — true `.padding(20)` parity. Without
        // this, glyphs start at 20 + 5 = 25pt (the sibling editable
        // `InputNSTextView` zeroes it for the same reason).
        textView.textContainer?.lineFragmentPadding = 0
        scroll.documentView = textView

        // Divider + trailing Done row (UserBubbleSheetView.swift:21-28).
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(
            title: String(localized: "Done"), target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"  // default action → Return resolves here.
        done.translatesAutoresizingMaskIntoConstraints = false
        doneButton = done

        let doneRow = NSView()
        doneRow.translatesAutoresizingMaskIntoConstraints = false
        doneRow.addSubview(done)

        root.addSubview(scroll)
        root.addSubview(divider)
        root.addSubview(doneRow)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            doneRow.topAnchor.constraint(equalTo: divider.bottomAnchor),
            doneRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            doneRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            doneRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            done.trailingAnchor.constraint(
                equalTo: doneRow.trailingAnchor, constant: -Self.doneRowPadding),
            done.topAnchor.constraint(equalTo: doneRow.topAnchor, constant: Self.doneRowPadding),
            done.bottomAnchor.constraint(
                equalTo: doneRow.bottomAnchor, constant: -Self.doneRowPadding),
        ])

        self.textView = textView
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Done is the initialFirstResponder so Return resolves to it BEFORE the
        // selectable text view can swallow the keystroke (§4.7-2). The text
        // view still becomes first responder on click for ⌘C copy.
        view.window?.initialFirstResponder = doneButton
        view.window?.makeFirstResponder(doneButton)
    }

    // MARK: - Dismiss surfaces

    @objc private func donePressed() { onDismiss() }

    /// Esc → dismiss (§4.7-4).
    override func cancelOperation(_ sender: Any?) { onDismiss() }
}

/// A read-only selectable `NSTextView` that forwards Return to `onNewline`
/// instead of inserting a line (the field is non-editable, so a stray Return
/// reaching the text view would otherwise be a no-op that swallows the
/// keystroke before the Done button's default action — §4.7-2).
private final class ForwardingNewlineTextView: NSTextView {
    var onNewline: (() -> Void)?
    nonisolated deinit {}

    override func insertNewline(_ sender: Any?) {
        onNewline?()
    }
}
