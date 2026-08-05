import AppKit

/// Pictures for the demo's image rows: drawn, written to a temporary directory,
/// and handed over as `file:` URLs.
///
/// **Files rather than `NSImage`s, on purpose.** `ImageGridView` is built from
/// URLs and everything interesting about it happens on the way from one to a
/// tile — the header read that answers a height, the thumbnail decode, the cache
/// that decides whether a picture fades in or is simply there. Handing it images
/// already in memory would leave every one of those paths unexercised on the one
/// screen that exists to look at them.
///
/// No asset catalogue and no binary blobs in the package, because what the mosaic
/// needs is a set of *shapes* and a drawing handler produces those exactly, in any
/// number, including the awkward ones — a 3:1 panorama, a 1:3 column — that push
/// the layout past its hand-written arrangements into the search.
///
/// Each carries its index and its ratio in the middle, because the question being
/// asked of this screen is "which picture ended up where, at what shape", and that
/// is unanswerable when every tile is an anonymous gradient.
enum DemoImage {

    /// Assorted proportions, in a fixed order so a screenshot is comparable with
    /// the last one.
    static let ratios: [CGFloat] = [
        1.5, 0.75, 1.0, 3.0, 1.33, 0.62, 1.78, 1.0, 0.8, 2.4, 1.2, 0.9,
    ]

    /// `count` pictures starting at `offset` in the ratio list, wrapping.
    static func group(_ count: Int, offset: Int = 0) -> [URL] {
        (0..<count).compactMap { index in
            url(forSlot: (offset + index) % ratios.count)
        }
    }

    /// An address that resolves to nothing, for the tile that has to show what
    /// "there is no picture here" looks like.
    static let missing = URL(fileURLWithPath: "/tmp/ccterm-demo/does-not-exist.png")

    /// A remote address, which the transcript lays out at the fallback size
    /// **before** knowing anything about it and does not re-lay-out afterwards.
    /// Whether it resolves is beside the point — either way the row's shape was
    /// decided without waiting for it, which is the behaviour to look at.
    static let remote = URL(string: "https://example.invalid/picture.png")!

    // MARK: - Writing them out

    private static let directory: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccterm-demo-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Written once per slot and reused; the script asks for the same ratios
    /// several times over.
    private static var written: [Int: URL] = [:]

    private static func url(forSlot slot: Int) -> URL? {
        if let existing = written[slot] { return existing }

        let destination = directory.appendingPathComponent("demo-\(slot).png")
        guard let data = png(ratio: ratios[slot], seed: slot) else { return nil }
        do {
            try data.write(to: destination)
        } catch {
            return nil
        }
        written[slot] = destination
        return destination
    }

    /// A picture 480 points on its long side at the given proportion.
    ///
    /// Sized so a tile is usually scaling *down*, which is what a real photograph
    /// does — one that had to be scaled up would hide exactly the resampling the
    /// aspect-fill is there to get right.
    private static func png(ratio: CGFloat, seed: Int) -> Data? {
        let long: CGFloat = 480
        let size =
            ratio >= 1
            ? CGSize(width: long, height: (long / ratio).rounded())
            : CGSize(width: (long * ratio).rounded(), height: long)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // A two-stop diagonal, hue stepped per picture, so neighbouring tiles
            // in a mosaic never read as one continuous surface.
            let hue = CGFloat((seed * 37) % 360) / 360
            NSGradient(
                starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
                ending: NSColor(
                    hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7,
                    brightness: 0.45, alpha: 1)
            )?.draw(in: rect, angle: -60)

            // A grid, so a crop is visible as a crop rather than as a slightly
            // different gradient.
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            context.setLineWidth(1)
            for x in stride(from: rect.minX, through: rect.maxX, by: 40) {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for y in stride(from: rect.minY, through: rect.maxY, by: 40) {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let label = NSAttributedString(
                string: "\(seed + 1)\n\(String(format: "%.2f", ratio))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                    .paragraphStyle: paragraph,
                ])
            let bounds = label.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
            label.draw(
                with: NSRect(
                    x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2,
                    width: bounds.width, height: bounds.height),
                options: [.usesLineFragmentOrigin])

            return true
        }

        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
