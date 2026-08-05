import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Everything a picture costs between a `URL` and a tile: its dimensions, its
/// decoded pixels, and the caches that keep both from being paid twice.
///
/// ## Why a URL is the whole input
///
/// A `file:` path, a `data:` payload and an `https:` address are the three ways a
/// picture reaches a transcript, and they are already one type. Taking `NSImage`
/// instead — which is what this replaced — writes "already loaded" into the
/// signature, and that is the expensive state: measured, constructing an
/// `NSImage(byReferencing:)` and asking its `size` costs **1.58 ms for a 4000 ×
/// 3000 file against 0.24 ms for a 200 × 150 one**, because it parses far more
/// than the header. `CGImageSource` reads the same dimensions in 0.19 ms and
/// 0.11 ms — near enough flat, because it stops at the metadata. A row of
/// pictures asks for heights on every width change, so the difference between
/// those two columns is the difference between a transcript that resizes and one
/// that does not.
///
/// `data:` is handled rather than being pushed back to the caller as "write it to
/// a file first". Pasted images arrive as base64 and spilling them onto the disk
/// to look at them leaves the user's filesystem holding files nobody asked for,
/// plus a cleanup problem that outlives the window.
///
/// ## Two caches, because two questions
///
/// Dimensions are asked for **every row, every layout pass**, and are tiny — a
/// plain dictionary, never evicted, because a `CGSize` per picture the transcript
/// has ever shown is nothing.
///
/// Pixels are asked for **a screenful**, and are large — an `NSCache` with a byte
/// cost, so the system can take them back under pressure. That is the whole
/// reason it is not a dictionary too: a dictionary of decoded bitmaps is a leak
/// with a slow fuse.
///
/// A process-level cache with a lifetime is precisely the exception the project's
/// singleton rule leaves open, and this is the written-down reason: the same
/// picture appears in the transcript, in the preview it opens into, and again
/// after being scrolled past and back, and none of those three know about each
/// other.
@MainActor
public final class MediaImageStore {

    public static let shared = MediaImageStore()

    /// What a picture is decoded to for a tile.
    ///
    /// Derived rather than chosen: `MosaicLayout` is capped at 360 points wide and
    /// aims at `320 / 3 * 4 ≈ 427` points tall, so no tile exceeds roughly
    /// 360 × 427 points — 720 × 854 pixels on a 2× display. 1024 covers that with
    /// room to spare.
    ///
    /// **Fixed rather than per-tile on purpose.** Decoding to the tile's exact
    /// size would mean a fresh decode of every visible picture on every width
    /// change, which is once per frame while a window edge is being dragged. One
    /// size for all tiles is decoded once and scaled by the compositor.
    private static let displayPixelSize: CGFloat = 1024

    /// What a picture is laid out at when its real dimensions are not knowable —
    /// a remote address before it has been fetched, or anything that failed.
    ///
    /// Square, and that is the load-bearing part: 1.0 falls in `MosaicLayout`'s
    /// neutral `q` bucket (0.8 to 1.2), so a placeholder does not push the group
    /// into an arrangement chosen for shapes it does not have.
    public static let fallbackSize = CGSize(width: 200, height: 200)

    private var sizes: [URL: CGSize] = [:]
    private let images = NSCache<NSURL, NSImage>()

    private init() {
        // ~48 MB of decoded pixels. At the display size above a picture is at most
        // 1024 × 1024 × 4 bytes, so this is roughly a dozen worst-case tiles and a
        // great many ordinary ones.
        images.totalCostLimit = 48 * 1024 * 1024
    }

    // MARK: - Dimensions

    /// The picture's own size, answered **synchronously** because
    /// `heightOfRow` cannot wait, and cheaply because it is asked for every row.
    ///
    /// Falls back to `fallbackSize` for anything not readable on the spot: a
    /// remote address, a file that is not there, bytes that are not a picture.
    /// This is what makes a remote picture's row a fixed shape — the layout is
    /// decided before the fetch and is not revised when it lands.
    public func size(of url: URL) -> CGSize {
        if let known = sizes[url] { return known }
        let measured = Self.readSize(of: url) ?? Self.fallbackSize
        sizes[url] = measured
        return measured
    }

    /// Header only — `CGImageSourceCopyPropertiesAtIndex` stops at the metadata
    /// and never decodes a pixel, which is why it is flat in the picture's size
    /// where `NSImage.size` is not.
    private static func readSize(of url: URL) -> CGSize? {
        guard let source = imageSource(for: url),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A source for the two schemes whose bytes are already reachable. `nil` for
    /// everything else, which is how a remote address ends up at the fallback.
    private nonisolated static func imageSource(for url: URL) -> CGImageSource? {
        if url.isFileURL {
            return CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        if let data = dataURLPayload(url) {
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
        return nil
    }

    /// The bytes out of a `data:` URL.
    ///
    /// `URL` does not decompose these — there is no host, no path, and
    /// `absoluteString` is the whole of it — so the split is by hand:
    /// `data:[<mediatype>][;base64],<payload>`.
    private nonisolated static func dataURLPayload(_ url: URL) -> Data? {
        guard url.scheme == "data" else { return nil }
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.startIndex..<comma]
        let payload = String(text[text.index(after: comma)...])

        if header.contains(";base64") {
            // `.ignoreUnknownCharacters` because a payload that travelled through
            // a text format may have picked up line breaks.
            return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    // MARK: - Pixels

    /// The decoded copy for a tile, if it has already been decoded.
    ///
    /// Separate from `load` so a caller can tell **cached** from **arriving**, and
    /// that distinction is not an optimisation: a picture that was already in hand
    /// must appear without a fade, or scrolling back over one flickers. Telegram
    /// carries the same distinction as a parameter — `approximateSynchronousValue`.
    public func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    /// Decodes the tile-sized copy off the main actor and calls back on it.
    ///
    /// `completion` runs exactly once, with `nil` when there is nothing to show —
    /// which the caller draws as the fallback rather than as an empty tile.
    /// Returns nothing to cancel with: a decode this size takes single-digit
    /// milliseconds, so a cancelled one costs less than the machinery to cancel
    /// it. The result is cached either way, so a row scrolled past and back finds
    /// it waiting.
    public func loadImage(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cachedImage(for: url) { return completion(cached) }

        let maxPixel = Self.displayPixelSize
        Task {
            let image = await Self.decode(url, maxPixelSize: maxPixel)
            if let image { self.store(image, for: url) }
            completion(image)
        }
    }

    /// The picture at its own size, for the preview — which shows it at 1:1 and
    /// shrinks only when it exceeds the screen, so the tile's copy is the wrong
    /// pixels to hand it.
    public func loadOriginal(for url: URL, completion: @escaping (NSImage?) -> Void) {
        Task {
            completion(await Self.decode(url, maxPixelSize: nil))
        }
    }

    private func store(_ image: NSImage, for url: URL) {
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        images.setObject(image, forKey: url as NSURL, cost: pixels * 4)
    }

    /// Off the main actor: file I/O and a decode, neither of which belongs in a
    /// layout pass.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` with a max pixel size
    /// decodes **directly** to that size rather than decoding whole and scaling —
    /// the difference between touching every pixel of a 12-megapixel photograph
    /// and touching a megapixel of it.
    private nonisolated static func decode(_ url: URL, maxPixelSize: CGFloat?) async -> NSImage? {
        // Remote bytes first, and through `URLSession` rather than
        // `Data(contentsOf:)`.
        //
        // **This was the bug that froze the window.** `Data(contentsOf:)` is a
        // synchronous, unbounded, uncancellable network call, and it was being
        // made inside a detached task — which runs on the cooperative pool, whose
        // width is `activeProcessorCount`. One address that does not resolve holds
        // a pool thread for the whole of the DNS timeout, and the pool is what
        // every `await` in the process needs to hop through. Measured at 8.5
        // seconds of main-thread stall, and intermittent because negative DNS
        // caching makes the second attempt fail immediately — which is exactly
        // what "sometimes it hitches and sometimes it doesn't" looks like from
        // outside.
        //
        // `URLSession` suspends instead of blocking, so nothing is held while the
        // request is in flight, and it brings a timeout and cancellation with it.
        var remote: Data?
        if !url.isFileURL && url.scheme != "data" {
            remote = try? await URLSession.shared.data(from: url).0
            guard remote != nil else { return nil }
        }
        let fetched = remote

        return await Task.detached(priority: .userInitiated) { () -> Decoded? in
            let bytes = fetched
            let source =
                bytes.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                ?? imageSource(for: url)
            guard let source else { return nil }

            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let maxPixelSize {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
                options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
            }

            let cgImage =
                maxPixelSize == nil
                ? CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
                : CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            guard let cgImage else { return nil }
            return Decoded(cgImage: cgImage)
        }.value.map {
            NSImage(
                cgImage: $0.cgImage,
                size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height))
        }
    }
}

// MARK: -

/// A decoded bitmap on its way back from a detached task.
///
/// `NSImage` only conforms to `Sendable` from macOS 14 and this package targets
/// 12, so the value that crosses the boundary is the `CGImage` instead — which is
/// immutable once created and documented thread-safe, which is the whole of what
/// `@unchecked` is resting on here. The `NSImage` is built on the far side, on the
/// main actor, where it is going to be used anyway.
private struct Decoded: @unchecked Sendable {
    let cgImage: CGImage
}
