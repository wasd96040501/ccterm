import XCTest
@testable import ccterm

/// `OpenMetrics.format` 纯函数快照测试。格式必须稳定 —— 生产日志线下 grep /
/// line-based 聚合都依赖它。
final class TranscriptOpenMetricsTests: XCTestCase {

    func testBasicSnapshotFormatting() {
        let s = OpenMetrics.Snapshot(
            ttfpMs: 23,
            fullMs: 180,
            entryCount: 420,
            phase1Rows: 12,
            cacheHit: 3,
            cacheMiss: 0,
            width: 780,
            viewportTag: "ok",
            scrollTag: "bottom")
        let out = OpenMetrics.format(s)
        XCTAssertEqual(
            out,
            "open ttfp=23ms full=180ms entries=420 phase1Rows=12 cacheHit=3 "
            + "cacheMiss=0 width=780 fallback=0 budget=ok scroll=bottom")
    }

    /// fullMs=nil → 不打印 full 字段，保留其它。
    func testNilFullMsOmitsField() {
        let s = OpenMetrics.Snapshot(
            ttfpMs: 12,
            fullMs: nil,
            entryCount: 10,
            phase1Rows: 5,
            cacheHit: 0,
            cacheMiss: 0,
            width: 640,
            viewportTag: "ok",
            scrollTag: "bottom")
        let out = OpenMetrics.format(s)
        XCTAssertFalse(out.contains("full="))
        XCTAssertTrue(out.contains("ttfp=12ms"))
    }

    /// 非 ok budget → fallback=1，budget 标签保留。
    func testFallbackTagIncludesBudgetSource() {
        let s = OpenMetrics.Snapshot(
            ttfpMs: 80,
            fullMs: 400,
            entryCount: 200,
            phase1Rows: 6,
            cacheHit: 0,
            cacheMiss: 6,
            width: 720,
            viewportTag: "fallback-const",
            scrollTag: "bottom")
        let out = OpenMetrics.format(s)
        XCTAssertTrue(out.contains("fallback=1"))
        XCTAssertTrue(out.contains("budget=fallback-const"))
    }

    /// cacheHit / cacheMiss 0 也要保留 —— 不 omit，下游聚合需要完整样本。
    func testZeroCacheCountsAreRetained() {
        let s = OpenMetrics.Snapshot(
            ttfpMs: 1,
            fullMs: 2,
            entryCount: 1,
            phase1Rows: 1,
            cacheHit: 0,
            cacheMiss: 0,
            width: 1,
            viewportTag: "ok",
            scrollTag: "bottom")
        let out = OpenMetrics.format(s)
        XCTAssertTrue(out.contains("cacheHit=0"))
        XCTAssertTrue(out.contains("cacheMiss=0"))
    }

    func testScrollTagPropagated() {
        for tag in ["preserve", "bottom", "anchor"] {
            let s = OpenMetrics.Snapshot(
                ttfpMs: 10,
                fullMs: 20,
                entryCount: 5,
                phase1Rows: 5,
                cacheHit: 1,
                cacheMiss: 1,
                width: 500,
                viewportTag: "ok",
                scrollTag: tag)
            XCTAssertTrue(OpenMetrics.format(s).contains("scroll=\(tag)"),
                "scroll tag '\(tag)' must appear in formatted output")
        }
    }
}
