import AppKit

/// A host at its real width, scaled down whole when the column is narrower:
/// the content is laid out at `width` always — never re-laid out narrower —
/// and this view, as wide as the room allows (`width` at most), shows it
/// through a `bounds` that stays `width` wide, so everything in it, drawing
/// and hit testing alike, is the same layout smaller.
///
/// `height` is the host's real height; `nil` asks the content, at `width`.
final class ScaledHost: NSView {
    private let content: NSView
    private let width: CGFloat
    private let fixedHeight: CGFloat?
    private var heightConstraint: NSLayoutConstraint?

    init(content: NSView, width: CGFloat, height: CGFloat? = nil) {
        self.content = content
        self.width = width
        fixedHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
            widthAnchor.constraint(lessThanOrEqualToConstant: width),
        ])
        if let height {
            content.heightAnchor.constraint(equalToConstant: height).isActive = true
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: height / width).isActive = true
        } else {
            let constraint = heightAnchor.constraint(equalToConstant: content.fittingSize.height)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The factor the content is drawn at.
    private var scale: CGFloat { frame.width > 0 ? frame.width / width : 1 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = scale
        setBoundsSize(NSSize(width: width, height: newSize.height / scale))
    }

    override func layout() {
        super.layout()
        guard fixedHeight == nil, let heightConstraint else { return }
        // The content's own height at `width`, as it is now.
        let height = (content.fittingSize.height * scale).rounded(.up)
        if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
    }
}
