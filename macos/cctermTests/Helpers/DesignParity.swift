import AppKit
import XCTest

/// A native render beside the design's own render of the same part. The design
/// sheet (`design/transcript/index.html`) is captured at @2x by
/// `make design-shots` into `/tmp/design-shots`, each part with its size in pt
/// (`<scheme>-parts.json`). `write` puts the design and ours side by side in
/// `/tmp/ccterm-parity/<scheme>-<id>.png`, both at 2 px per pt — a checklist
/// for what is missing or misplaced. The numbers to build to are the
/// stylesheet's (`preview-live.css`), not the browser's pixels.
@MainActor
enum DesignParity {
    struct Part: Decodable {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let cap: String
        let text: String
    }

    enum Scheme: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }

        /// The sheet's `--page`, under every specimen's stage.
        var page: NSColor {
            self == .light
                ? NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 1)
                : NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0F / 255, alpha: 1)
        }
    }

    static let shots = URL(fileURLWithPath: "/tmp/design-shots")
    static let directory = URL(fileURLWithPath: "/tmp/ccterm-parity")

    /// The design's part `id` (`part-07-comp0`), or a skip until the sheet is captured.
    static func part(_ id: String, _ scheme: Scheme) throws -> Part {
        let manifest = shots.appendingPathComponent("\(scheme.rawValue)-parts.json")
        guard let data = try? Data(contentsOf: manifest) else {
            throw XCTSkip("no design capture at \(shots.path) — run `make design-shots`")
        }
        let parts = try JSONDecoder().decode([Part].self, from: data)
        return try XCTUnwrap(parts.first { $0.name == "\(scheme.rawValue)-\(id)" }, "the design has no \(id)")
    }

    /// Writes design | ours for part `id`. Returns the file.
    @discardableResult
    static func write(_ id: String, _ scheme: Scheme, ours: NSImage) throws -> URL {
        let designURL = shots.appendingPathComponent("\(scheme.rawValue)-\(id).png")
        let design = try XCTUnwrap(NSImage(contentsOf: designURL), "no design render \(designURL.path)")
        // Both at 2 px per pt, whatever the screen the render came from.
        let left = size(design, pt: try part(id, scheme))
        let right = NSSize(width: ours.size.width * 2, height: ours.size.height * 2)
        let pad: CGFloat = 24
        let label: CGFloat = 40
        let width = left.width + right.width + pad * 3
        let height = max(left.height, right.height) + label + pad * 2
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = context
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let top = height - pad - label
        let columns = [pad, pad * 2 + left.width]
        func caption(_ text: String, at x: CGFloat) {
            NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white]
            ).draw(at: NSPoint(x: x, y: top + 6))
        }
        caption("design", at: columns[0])
        caption("ours", at: columns[1])
        design.draw(in: NSRect(x: columns[0], y: top - left.height, width: left.width, height: left.height))
        ours.draw(in: NSRect(x: columns[1], y: top - right.height, width: right.width, height: right.height))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(scheme.rawValue)-\(id).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private static func size(_ image: NSImage, pt part: Part) -> NSSize {
        NSSize(width: (part.width * 2).rounded(), height: (part.height * 2).rounded())
    }
}
