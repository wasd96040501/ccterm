import AppKit
import CoreText
import XCTest

@testable import ccterm

/// Wall-clock benchmark for `TextLayout.make` / `draw` and a few hand-rolled
/// alternatives. Uses `mach_absolute_time` for ns-precision and reports
/// best-of-N to suppress jitter.
///
/// Skipped by default — full `make test` runs do not execute these. Opt in via
/// env var. Intended to be run with optimizer on (Release equivalent):
///
///     CCTERM_RUN_BENCHMARKS=1 xcodebuild test \
///       -project macos/ccterm.xcodeproj -scheme ccterm \
///       -destination 'platform=macOS' \
///       -only-testing:cctermTests/TextLayoutBenchmarkTests \
///       SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
///       CODE_SIGNING_ALLOWED=NO
///
/// Output goes through `NSLog` so xcodebuild surfaces it.
@MainActor
final class TextLayoutBenchmarkTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CCTERM_RUN_BENCHMARKS"] == "1",
            "Skipped — set CCTERM_RUN_BENCHMARKS=1 to run benchmarks.")
    }

    // MARK: - Timing primitives

    private struct Stats {
        let min_ns: UInt64
        let median_ns: UInt64
        let mean_ns: UInt64
        let iters: Int
    }

    private static var timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    private static func ticksToNs(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Run `body` `iters` times. Returns min / median / mean per call (ns).
    @inline(never)
    private func bench(iters: Int, _ body: () -> Void) -> Stats {
        // Warmup
        for _ in 0..<min(iters, 50) { body() }

        var samples = [UInt64](repeating: 0, count: iters)
        for i in 0..<iters {
            let t0 = mach_absolute_time()
            body()
            let t1 = mach_absolute_time()
            samples[i] = Self.ticksToNs(t1 - t0)
        }
        samples.sort()
        let sum = samples.reduce(UInt64(0), +)
        return Stats(
            min_ns: samples.first!,
            median_ns: samples[samples.count / 2],
            mean_ns: sum / UInt64(iters),
            iters: iters)
    }

    // MARK: - Fixtures

    private static let asciiBase =
        "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. "
    private static let cjkBase =
        "敏捷的棕色狐狸跳过了懒狗。中文排版需要测试 CJK 字形开销以及和拉丁字符混排时的表现差异。"

    private func makeASCII(chars: Int) -> String {
        var s = ""
        while s.count < chars { s += Self.asciiBase }
        return String(s.prefix(chars))
    }

    private func makeCJK(chars: Int) -> String {
        var s = ""
        while s.count < chars { s += Self.cjkBase }
        return String(s.prefix(chars))
    }

    private func paragraph(_ s: String) -> NSAttributedString {
        BlockStyle.paragraphAttributed(inlines: [.text(s)])
    }

    private func heading(_ s: String) -> NSAttributedString {
        BlockStyle.headingAttributed(level: 1, inlines: [.text(s)])
    }

    // MARK: - Hand-rolled "height-only" alternatives (for comparison)

    /// Variant A: typeset + count lines, but skip `CTTypesetterCreateLine` /
    /// per-line bounds. Use font's uniform line height. Saves per-line
    /// CTLine alloc + metrics read.
    @inline(never)
    private func heightOnly_uniform(_ attr: NSAttributedString, font: NSFont, maxWidth: CGFloat)
        -> CGFloat
    {
        guard attr.length > 0, maxWidth > 0 else { return 0 }
        let typesetter = CTTypesetterCreateWithAttributedString(attr)
        let length = attr.length
        var lineCount = 0
        var start: CFIndex = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            guard count > 0 else { break }
            lineCount += 1
            start += count
        }
        let lineH = font.ascender - font.descender + font.leading
        return CGFloat(lineCount) * lineH
    }

    /// Variant B: full `TextLayout.make` (current production).
    @inline(never)
    private func heightOnly_full(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        TextLayout.make(attributed: attr, maxWidth: maxWidth).totalHeight
    }

    // MARK: - Draw harness

    /// A reusable bitmap context the size of the longest expected layout.
    private func makeContext(width: Int, height: Int) -> CGContext {
        let cs = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    }

    // MARK: - Driver

    private func run(label: String, attr: NSAttributedString, font: NSFont, width: CGFloat) {
        let charCount = attr.length

        // make full
        let makeStats = bench(iters: 200) {
            let l = TextLayout.make(attributed: attr, maxWidth: width)
            _ = l.totalHeight  // keep the result alive
        }
        // height-only (no CTLine alloc, uniform line height)
        let heightOnlyStats = bench(iters: 200) {
            _ = self.heightOnly_uniform(attr, font: font, maxWidth: width)
        }

        // Build one layout to drive draw bench
        let layout = TextLayout.make(attributed: attr, maxWidth: width)
        let ctx = makeContext(width: Int(width), height: max(64, Int(layout.totalHeight) + 16))

        // draw: best-of warm runs (glyph cache is hot after first iter)
        let drawStats = bench(iters: 200) {
            ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            layout.draw(in: ctx, origin: .zero)
        }

        let per100_make = makeStats.median_ns * 100 / UInt64(charCount)
        let per100_draw = drawStats.median_ns * 100 / UInt64(charCount)
        let per100_height = heightOnlyStats.median_ns * 100 / UInt64(charCount)

        NSLog(
            "=== BENCH %@ chars=%d width=%.0f ===", label, charCount, width)
        NSLog(
            "  make:           min=%6lluns median=%6lluns mean=%6lluns  per100ch=%6lluns",
            makeStats.min_ns, makeStats.median_ns, makeStats.mean_ns, per100_make)
        NSLog(
            "  height-only:    min=%6lluns median=%6lluns mean=%6lluns  per100ch=%6lluns",
            heightOnlyStats.min_ns, heightOnlyStats.median_ns, heightOnlyStats.mean_ns,
            per100_height)
        NSLog(
            "  draw (warm):    min=%6lluns median=%6lluns mean=%6lluns  per100ch=%6lluns",
            drawStats.min_ns, drawStats.median_ns, drawStats.mean_ns, per100_draw)
        NSLog(
            "  ratio: height-only / make = %.2fx, draw / make = %.2fx",
            Double(heightOnlyStats.median_ns) / Double(makeStats.median_ns),
            Double(drawStats.median_ns) / Double(makeStats.median_ns))
    }

    // MARK: - Tests

    func testBenchmarkASCIIParagraph() {
        for n in [100, 500, 2_000, 10_000] {
            let s = makeASCII(chars: n)
            run(label: "ASCII paragraph", attr: paragraph(s), font: BlockStyle.paragraphFont,
                width: 600)
        }
    }

    func testBenchmarkCJKParagraph() {
        for n in [100, 500, 2_000, 10_000] {
            let s = makeCJK(chars: n)
            run(label: "CJK paragraph", attr: paragraph(s), font: BlockStyle.paragraphFont,
                width: 600)
        }
    }

    func testBenchmarkASCIIHeading() {
        for n in [100, 500] {
            let s = makeASCII(chars: n)
            run(label: "ASCII heading", attr: heading(s),
                font: BlockStyle.headingFont(level: 1), width: 600)
        }
    }

    /// Cold-cache draw: first call after creation. Useful to see the worst-case
    /// glyph rasterization cost on a fresh layout.
    func testBenchmarkDrawColdVsWarm() {
        let s = makeASCII(chars: 2000)
        let attr = paragraph(s)
        let width: CGFloat = 600

        // Build many distinct layouts so each draw can't reuse the previous
        // CT-internal warm path. CG glyph cache is process-global so it
        // warms up fast even across distinct CTLines for the same font.
        var layouts: [TextLayout] = []
        for _ in 0..<200 {
            layouts.append(TextLayout.make(attributed: attr, maxWidth: width))
        }
        let ctx = makeContext(
            width: Int(width), height: max(64, Int(layouts[0].totalHeight) + 16))

        // Cold-ish: each iter uses a fresh layout
        var idx = 0
        let coldStats = bench(iters: 200) {
            ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            layouts[idx % layouts.count].draw(in: ctx, origin: .zero)
            idx += 1
        }

        // Warm: reuse same layout — same CTLines repeatedly drawn
        let warm = layouts[0]
        let warmStats = bench(iters: 200) {
            ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            warm.draw(in: ctx, origin: .zero)
        }

        NSLog("=== BENCH draw cold vs warm (ASCII 2000ch) ===")
        NSLog(
            "  cold (fresh layout):  min=%6lluns median=%6lluns",
            coldStats.min_ns, coldStats.median_ns)
        NSLog(
            "  warm (same layout):   min=%6lluns median=%6lluns",
            warmStats.min_ns, warmStats.median_ns)
    }
}
