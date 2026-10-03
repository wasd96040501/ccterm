import AppKit
import DisplayModels

/// A picture pasted into a prompt, beside the transcript at its size
/// (05-local.md): in a scroll view with overlay scrollers, centred when it is
/// smaller than the editor and scrolled when it is larger. The jump bar says its
/// pixel size and format (`DocumentHeader`).
///
/// Shown in its own colours in both appearances — a picture, not chrome.
@MainActor
public final class ImageDocumentViewController: NSViewController {
    private let image: PromptImage
    private let scroll = OverlayScrollView()
    private let host = ImageHostView()

    /// `title` is the image's name (*Image 2*), worded by the app.
    public init(_ image: PromptImage, title: String) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        view = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = host
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.show(NSImage(data: image.data), pixels: CGSize(width: image.width, height: image.height))
        setAccessibilityLabel()
    }

    private func setAccessibilityLabel() {
        host.setAccessibilityLabel("\(title ?? ""), \(image.dimensions)")
    }

    /// Overlay scrollers whatever *Show scroll bars* says, like every document.
    private final class OverlayScrollView: NSScrollView {
        override var scrollerStyle: NSScroller.Style {
            get { .overlay }
            set { super.scrollerStyle = .overlay }
        }
    }

    /// The picture at its size, with a margin; centred in the clip when smaller
    /// (`.imgdoc`: 24 pt around it, 6-pt corners, a hairline outside its edge).
    private final class ImageHostView: NSView {
        private static let margin: CGFloat = 24
        private static let radius: CGFloat = 6
        private let imageView = NSImageView()
        /// The hairline, outside the picture so it covers none of it.
        private let ring = CALayer()
        private var size = CGSize.zero

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            imageView.imageScaling = .scaleNone
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = Self.radius
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            addSubview(imageView)
            wantsLayer = true
            ring.borderWidth = 0.5
            ring.cornerRadius = Self.radius + 0.5
            ring.cornerCurve = .continuous
            layer?.addSublayer(ring)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.borderColor = NSColor.separatorColor.cgColor
            }
        }

        /// A screenshot's pixels at twice the points when the display does: the
        /// picture is drawn at its own point size, as Preview opens it.
        func show(_ image: NSImage?, pixels: CGSize) {
            imageView.image = image
            size = image?.size == .zero || image == nil ? pixels : (image?.size ?? pixels)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let clip = enclosingScrollView?.contentSize ?? bounds.size
            let width = max(clip.width, size.width + 2 * Self.margin)
            let height = max(clip.height, size.height + 2 * Self.margin)
            if frame.size != CGSize(width: width, height: height) {
                setFrameSize(CGSize(width: width, height: height))
            }
            imageView.frame = CGRect(
                x: ((width - size.width) / 2).rounded(), y: ((height - size.height) / 2).rounded(),
                width: size.width, height: size.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = imageView.frame.insetBy(dx: -0.5, dy: -0.5)
            ring.isHidden = size == .zero
            CATransaction.commit()
        }
    }
}
