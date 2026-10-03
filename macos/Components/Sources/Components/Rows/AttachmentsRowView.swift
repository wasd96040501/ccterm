import AppKit
import DisplayModels
import ImageIO

/// The pictures pasted into a prompt, as thumbnails over its bubble
/// (05-local.md *A prompt with pasted images*): 96 pt tall, as wide as the
/// picture's aspect says, 4 pt apart, right-aligned with the bubble and
/// wrapping within its 75 %. Continuous 10-pt corners and a 0.5-pt hairline, so
/// a white screenshot keeps its edge on a white page; numbered when there are
/// several. Hovering a picture's token in the bubble outlines its thumbnail in
/// the accent; a click opens the picture beside.
@MainActor
public final class AttachmentsRowView: NSView, PageRowView {
    public struct Model: Equatable {
        public var images: [PromptImage]
        /// *Image N* for each of `images`, worded by the app: the thumbnail's accessibility label.
        public var titles: [String]
        /// The picture number hovered in the bubble, outlined in the accent.
        public var highlighted: Int?

        public init(images: [PromptImage], titles: [String], highlighted: Int?) {
            self.images = images
            self.titles = titles
            self.highlighted = highlighted
        }
    }

    public weak var delegate: PageRowViewDelegate?

    static let thumbnailHeight: CGFloat = 96
    private static let gap: CGFloat = 4
    /// The bubble's share of the column.
    private static let share: CGFloat = 0.75

    private var thumbnails: [Thumbnail] = []
    private var images: [PromptImage] = []
    private var titles: [String] = []

    public override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Geometry

    /// The thumbnails' frames in `width`, by row, each row against the trailing
    /// edge: the same arithmetic the view lays out with.
    static func frames(for images: [PromptImage], width: CGFloat) -> [CGRect] {
        let limit = max(width * share, thumbnailHeight)
        var frames: [CGRect] = []
        var row: [CGSize] = []
        var y: CGFloat = 0

        func flush() {
            guard !row.isEmpty else { return }
            let total = row.map(\.width).reduce(0, +) + gap * CGFloat(row.count - 1)
            var x = width - total
            for size in row {
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                x += size.width + gap
            }
            y += thumbnailHeight + gap
            row = []
        }

        for image in images {
            var size = CGSize(width: (thumbnailHeight * image.aspectRatio).rounded(), height: thumbnailHeight)
            // A panorama wider than the bubble's share is scaled to it.
            if size.width > limit { size = CGSize(width: limit, height: (limit / image.aspectRatio).rounded()) }
            let used = row.map(\.width).reduce(0, +) + gap * CGFloat(row.count)
            if !row.isEmpty, used + size.width > limit { flush() }
            row.append(size)
        }
        flush()
        return frames
    }

    public static func height(for model: Model, width: CGFloat) -> CGFloat {
        guard let bottom = frames(for: model.images, width: width).map(\.maxY).max() else { return 0 }
        return bottom
    }

    public func configure(with model: Model) {
        images = model.images
        titles = model.titles
        while thumbnails.count < images.count {
            let thumbnail = Thumbnail()
            thumbnail.onClick = { [weak self] index, pinned in
                guard let self, self.images.indices.contains(index) else { return }
                self.delegate?.pageRowView(self, didRequestDocument: self.images[index].id, pinned: pinned)
            }
            addSubview(thumbnail)
            thumbnails.append(thumbnail)
        }
        for (index, thumbnail) in thumbnails.enumerated() {
            guard index < images.count else {
                thumbnail.isHidden = true
                continue
            }
            thumbnail.isHidden = false
            thumbnail.configure(
                images[index], title: titles.indices.contains(index) ? titles[index] : "", index: index,
                numbered: images.count > 1,
                isHighlighted: model.highlighted == images[index].number)
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let frames = Self.frames(for: images, width: bounds.width)
        for (index, frame) in frames.enumerated() where index < thumbnails.count {
            thumbnails[index].frame = frame
        }
    }

    // MARK: - One thumbnail

    private final class Thumbnail: NSView {
        var onClick: ((Int, Bool) -> Void)?

        private var index = 0
        private let picture = CALayer()
        private let ring = CALayer()
        private let plate = NSView()
        private let number = NSTextField(labelWithString: "")
        private var imageID: String?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false

            picture.cornerRadius = 10
            picture.cornerCurve = .continuous
            picture.masksToBounds = true
            picture.borderWidth = 0.5
            picture.contentsGravity = .resizeAspectFill
            layer?.addSublayer(picture)

            ring.cornerRadius = 11
            ring.cornerCurve = .continuous
            ring.borderWidth = 2
            ring.isHidden = true
            layer?.addSublayer(ring)

            // The badge (`.shot .n`): 11 pt on a dark 16-pt pill, 6 pt in from the bottom left.
            plate.wantsLayer = true
            plate.layer?.cornerRadius = 8
            plate.layer?.cornerCurve = .continuous
            plate.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            number.textColor = .white
            number.translatesAutoresizingMaskIntoConstraints = false
            plate.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(number)
            addSubview(plate)
            // As narrow as the digits allow, 16 at the least.
            let snug = plate.widthAnchor.constraint(equalToConstant: 16)
            snug.priority = .defaultLow
            NSLayoutConstraint.activate([
                snug,
                // 4 pt either side of the digits: the label's own 2 plus 2.
                number.leadingAnchor.constraint(greaterThanOrEqualTo: plate.leadingAnchor, constant: 2),
                number.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
                number.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
                plate.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
                plate.widthAnchor.constraint(greaterThanOrEqualTo: number.widthAnchor, constant: 4),
                plate.heightAnchor.constraint(equalToConstant: 16),
                plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }

        func configure(_ image: PromptImage, title: String, index: Int, numbered: Bool, isHighlighted: Bool) {
            self.index = index
            if imageID != image.id {
                imageID = image.id
                picture.contents = ThumbnailCache.image(for: image)
            }
            plate.isHidden = !numbered
            number.stringValue = "\(image.number)"
            ring.isHidden = !isHighlighted
            setAccessibilityLabel(title)
            needsLayout = true
            refreshColors()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.frame = bounds
            ring.frame = bounds.insetBy(dx: -3, dy: -3)
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshColors()
        }

        private func refreshColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                picture.borderColor = NSColor.separatorColor.cgColor
                ring.borderColor = NSColor.controlAccentColor.cgColor
            }
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(index, event.clickCount == 2)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

/// Thumbnails are decoded once, at the size they are drawn.
@MainActor
private enum ThumbnailCache {
    private static let cache = NSCache<NSString, CGImage>()

    static func image(for image: PromptImage) -> CGImage? {
        if let hit = cache.object(forKey: image.id as NSString) { return hit }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Twice the points, for retina, on the longer side.
            kCGImageSourceThumbnailMaxPixelSize: 2 * max(AttachmentsRowView.thumbnailHeight * image.aspectRatio, 96),
        ]
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        cache.setObject(thumbnail, forKey: image.id as NSString)
        return thumbnail
    }
}
