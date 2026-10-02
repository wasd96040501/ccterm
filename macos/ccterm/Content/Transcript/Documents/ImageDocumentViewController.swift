import AppKit

/// A picture pasted into a prompt, beside the transcript at its size
/// (05-local.md): in a scroll view with overlay scrollers, centred when it is
/// smaller than the editor and scrolled when it is larger. The jump bar says its
/// pixel size and format (`DocumentHeader`).
///
/// Shown in its own colours in both appearances — a picture, not chrome.
@MainActor
final class ImageDocumentViewController: NSViewController {
    private let image: PromptImage
    private let scroll = OverlayScrollView()
    private let host = ImageHostView()

    init(_ image: PromptImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        title = image.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
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
        host.setAccessibilityLabel("\(image.title), \(image.dimensions)")
    }

    /// Overlay scrollers whatever *Show scroll bars* says, like every document.
    private final class OverlayScrollView: NSScrollView {
        override var scrollerStyle: NSScroller.Style {
            get { .overlay }
            set { super.scrollerStyle = .overlay }
        }
    }

    /// The picture at its size, with a margin; centred in the clip when smaller.
    private final class ImageHostView: NSView {
        private static let margin: CGFloat = 20
        private let imageView = NSImageView()
        private var size = CGSize.zero

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            imageView.imageScaling = .scaleNone
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 4
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            addSubview(imageView)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }

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
        }
    }
}
