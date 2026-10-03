import AppKit

/// A host at its real width, scaled down whole when the column is narrower:
/// the content is laid out at `width` always — never re-laid out narrower —
/// and this view, as wide as the room allows (`width` at most), draws it
/// through a layer transform, so the narrow render is the same layout smaller.
///
/// The scale is a transform and not the view's `bounds`: AppKit snaps a
/// frame to the backing pixels of the scaled space, so Auto Layout inside a
/// scaled `bounds` finds its frames off the constraints by a fraction and
/// lays out again, for ever. The content lives in a stage this class sizes by
/// hand and lays itself out in at its real size; clicks are mapped back
/// into the stage in `hitTest`.
///
/// `height` is the host's real height; `nil` asks the content, at `width`.
final class ScaledHost: NSView {
    private let content: NSView
    private let stage = NSView()
    private let width: CGFloat
    private let fixedHeight: CGFloat?
    private var heightConstraint: NSLayoutConstraint?
    /// The content's height at `width`, in its own points.
    private var contentHeight: CGFloat

    init(content: NSView, width: CGFloat, height: CGFloat? = nil) {
        self.content = content
        self.width = width
        fixedHeight = height
        contentHeight = height ?? 0
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(stage)
        content.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: stage.topAnchor),
            content.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
            widthAnchor.constraint(lessThanOrEqualToConstant: width),
        ])
        if let height {
            content.heightAnchor.constraint(equalToConstant: height).isActive = true
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: height / width).isActive = true
        } else {
            contentHeight = content.fittingSize.height
            let constraint = heightAnchor.constraint(equalToConstant: contentHeight)
            constraint.isActive = true
            heightConstraint = constraint
        }
        wantsLayer = true
        stage.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// The factor the content is drawn at.
    private var scale: CGFloat { frame.width > 0 ? frame.width / width : 1 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScale()
    }

    private func applyScale() {
        stage.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        guard let layer else { return }
        // About the top-left corner, wherever the layer's geometry puts it.
        let corner = CGPoint(x: 0, y: layer.isGeometryFlipped ? 0 : bounds.height)
        var transform = CATransform3DMakeTranslation(corner.x, corner.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -corner.x, -corner.y, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = transform
        CATransaction.commit()
    }

    /// A point of the page maps into the stage at the content's real size.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return stage.hitTest(NSPoint(x: local.x / scale, y: local.y / scale)) ?? self
    }

    override func layout() {
        super.layout()
        guard fixedHeight == nil, let heightConstraint else { return }
        // The content's own height at `width`, as it is now.
        let measured = content.fittingSize.height
        guard abs(measured - contentHeight) > 0.5 else { return }
        contentHeight = measured
        applyScale()
        heightConstraint.constant = (contentHeight * scale).rounded(.up)
    }
}
