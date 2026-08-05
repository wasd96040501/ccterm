import AppKit

/// The whole of a user message the transcript had to cut short, in the same
/// overlay a picture opens into: a centred column on the darkened surround,
/// scrolling when it is longer than the screen.
///
/// ## Why not the transcript's own renderer
///
/// Mounting a second `TranscriptView` here with one uncollapsed row would have
/// been fewer lines and would have inherited the typography exactly. It is not
/// what this does, and the reason is the case the preview exists for. A row is
/// painted onto `SurfaceLayer`s sized to the row, split by paint phase and not
/// by height; with the line cap removed, a pasted file's row is as tall as the
/// file, and the backing store goes with it. `NSTextView` lays out and draws by
/// visible range, so length stops being a question — and selection, find and
/// copy arrive with it rather than being re-earned.
///
/// The message is plain text on both sides of the seam — `UserMessage` renders
/// it verbatim on purpose, so that what was typed is what is shown — which is
/// what makes the two renderers agree without sharing code.
///
/// ## The face
///
/// Larger than the transcript's, deliberately, and **not** derived from it. A
/// row in a list is read in passing at a size chosen against the rows around it;
/// a column alone on a darkened screen is read at length, and wants the size a
/// document would use. Two independent decisions about two different problems,
/// so this is a constant here rather than the transcript's plus a delta.
@MainActor
public final class MessagePreviewView: NSView, MediaOverlayContent {

    /// Against the transcript's 14. Chosen for reading a long paste at arm's
    /// length, not by adding to the row size.
    private static let fontSize: CGFloat = 17

    /// A measure, not a fraction of the screen: past roughly ninety characters a
    /// line the eye loses its place on the way back to the left margin, and a
    /// 27-inch display would otherwise give it three hundred.
    private static let maxWidth: CGFloat = 760

    /// `UserMessage`'s own padding and radius, so the card the message lands in
    /// is recognisably the bubble it left.
    private static let horizontalPadding: CGFloat = 22
    private static let verticalPadding: CGFloat = 20
    private static let cornerRadius: CGFloat = 14

    /// The bubble's accent tint is 15% in the transcript, where it sits on the
    /// window's own background. Here it sits on a 90% black scrim, which eats
    /// most of it — so the tint is raised to hold the same *apparent* strength
    /// rather than the same number.
    private static let cardTint: CGFloat = 0.28

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let card = NSView()
    private let text: NSAttributedString

    public init(message: String) {
        self.text = Self.attributed(message)
        super.init(frame: .zero)
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.masksToBounds = true
        addSubview(card)

        textView.isEditable = false
        // Selectable, because the reason a reader opens their own long prompt is
        // usually to take part of it back out.
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(
            width: Self.horizontalPadding, height: Self.verticalPadding)

        // The five lines that make an `NSTextView` wrap to its scroll view's
        // width and grow downward without bound. Leaving any of them out is the
        // classic failure — the view stays one line tall inside a scroller that
        // has nothing to scroll — and it is what this looked like before.
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.textStorage?.setAttributedString(text)

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        // Over a dark scrim the light knob is the legible one, and AppKit will
        // not derive that from the window's appearance for a borderless panel.
        scrollView.scrollerKnobStyle = .light
        card.addSubview(scrollView)

        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MessagePreviewView is code-only; init(coder:) is unavailable")
    }

    private static func attributed(_ message: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // Looser than a row's, for the same reason the face is larger: a long
        // column needs more air between lines than a bubble three lines tall.
        paragraph.lineHeightMultiple = 1.28
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: paragraph,
            ])
    }

    private func updateColors() {
        card.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(Self.cardTint).cgColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.28)
        ]
    }

    /// A `CGColor` on a layer is resolved once and does not follow the
    /// appearance, so the accent has to be re-read by hand when it changes.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // MARK: - MediaOverlayContent

    /// A column of at most `maxWidth`, centred, tall enough for the message and
    /// no taller than the space — past which the scroller takes over.
    public func overlayFrame(in available: NSRect) -> NSRect {
        let width = min(Self.maxWidth, available.width - 80)
        let height = min(measuredHeight(forWidth: width), available.height)
        return NSRect(
            x: available.midX - width / 2, y: available.midY - height / 2,
            width: width, height: height)
    }

    /// What the text comes to at `width`, measured through a layout stack of its
    /// own rather than the live one.
    ///
    /// The live container has `widthTracksTextView` on — which is what makes the
    /// text wrap once it is in the scroll view — and that flag *overwrites*
    /// `containerSize` on the next layout pass. Setting a width on it and reading
    /// the result back therefore measures whatever the view's width happened to
    /// be, which at this point is zero. A throwaway stack has no view to track
    /// and is not disturbed by having been asked.
    ///
    /// A fresh `NSTextContainer` carries the same 5-point line fragment padding
    /// the text view's does, so the two agree without that number appearing here.
    private func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(
                width: width - Self.horizontalPadding * 2,
                height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height + Self.verticalPadding * 2
    }

    public override func layout() {
        super.layout()
        card.frame = bounds
        scrollView.frame = card.bounds
    }
}
