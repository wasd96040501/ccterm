import AppKit
import XCTest

@testable import TranscriptKit

/// Throwaway — renders one document covering every block shape, so the paint
/// migration can be checked against a byte-identical reference.
final class TmpRenderProbe: XCTestCase {

    /// `/tmp/kit-ref` before the migration, `/tmp/kit-new` after.
    private var directory: String {
        ProcessInfo.processInfo.environment["KIT_RENDER_DIR"] ?? "/tmp/kit-ref"
    }

    func testRenderEveryShape() throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        try render(Self.source, to: "\(directory)/all-light.png")
        try dark.performAsCurrentDrawingAppearance {
            try? render(Self.source, to: "\(directory)/all-dark.png")
        }
        try render(Self.source, to: "\(directory)/all-narrow.png", width: 320)
    }

    private func render(_ source: String, to path: String, width: CGFloat = 660) throws {
        let block = MarkdownLayout.make(source).measure(width)
        let size = CGSize(width: width + 40, height: block.size.height + 40)
        let scale = 2

        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size

        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        block.draw(
            at: CGPoint(x: 20, y: 20), in: ctx, dirty: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: path))
    }

    /// Every shape `MarkdownLayout` can produce, in one document.
    private static let source = #"""
        # Heading one

        A paragraph with *emphasis*, **strong**, ~~struck~~, `inline code`, a
        [link](https://example.com), and a bare https://github.com/apple/swift.

        ## Heading two

        ### Heading three

        #### Four
        ##### Five
        ###### Six

        - A bullet item
        - One with a sub-list:
          - Second level
            - Third level
        - [x] Checked
        - [ ] Unchecked

        8. Eighth
        9. Ninth
        10. Tenth

        - An item holding two paragraphs.

          The second one.

        - And one holding a code block:

          ```swift
          BlockStack(rows, spacing: 6).measure(width)
          ```

        ```swift
        func height(ofRow row: Int) -> CGFloat {
            MarkdownLayout.make(source).measure(contentWidth).size.height
        }
        ```

        ```
        no language on this fence
        ```

            an indented block

        | Mechanism | Cardinality | Talks back | Lifecycle |
        |:----------|:-----------:|-----------:|-----------|
        | target-action | 1:1 | no | weak target |
        | delegate | 1:1 | **yes** | `weak var delegate` |
        | NotificationCenter | 1:many | no | remove before `deinit` |
        | KVO | 1:many | no | observation alive = observing |

        > A quote, and it nests:
        >
        > > ```swift
        > > struct Blockquote: Layout { let content: Layout }
        > > ```
        > >
        > > - including a list
        > > - and a second item
        >
        > Back out one level.

        ---

        A closing paragraph after the rule.\
        With a hard break in it.
        """#
}
