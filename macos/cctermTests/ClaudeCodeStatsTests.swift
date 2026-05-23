import XCTest

@testable import ccterm

/// Validates the Swift port of the desktop app's `SNr()` stats
/// aggregator against a Python reference implementation that lives in
/// `macos/scripts/generate-claude-code-stats-fixtures.py`. The Python
/// script bakes a redacted snapshot of one developer's `~/.claude`
/// (cache + a handful of recent JSONLs with all message content
/// replaced by `<redacted-len…>`) into
/// `Fixtures/ClaudeCodeStats/`, plus an `expected.json` snapshot of
/// what the Python aggregator produced over that same fixture. This
/// test then re-runs the Swift aggregator over the same fixture and
/// asserts the two outputs match.
///
/// Two implementations of one algorithm in two different languages
/// agreeing on a real (if anonymized) workload is what catches the
/// fiddly bits — bucket-merge order, subagent-day rules, hour
/// localization, fractional-second timestamps.
final class ClaudeCodeStatsTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeCodeStats", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixtureRoot.path) else {
            XCTFail(
                "Missing fixture at \(fixtureRoot.path). "
                    + "Run: python3 macos/scripts/generate-claude-code-stats-fixtures.py")
            return
        }

        // Copy the fixture into a unique tmp so each parallel test
        // process touches its own mtimes and never dirties the
        // working tree.
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureRoot, to: tmpRoot)
        addTeardownBlock { [tmpRoot] in
            if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        }

        // Bump every JSONL mtime past the cache cutoff so the
        // aggregator's mtime filter picks them up. `git checkout` /
        // `cp -r` both reset mtime to "now", and "now" on CI may
        // happen to be < `lastComputedDate + 1d` (the fixture is
        // time-pinned).
        let meta = try loadMeta(from: tmpRoot)
        let projects = tmpRoot.appendingPathComponent("projects", isDirectory: true)
        if let walker = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: nil)
        {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                try FileManager.default.setAttributes(
                    [.modificationDate: meta.today], ofItemAtPath: url.path)
            }
        }
    }

    func testMatchesPythonReferenceAggregation() throws {
        let meta = try loadMeta(from: tmpRoot)
        let actual = ClaudeCodeStats.aggregate(
            claudeRoot: tmpRoot,
            today: meta.today,
            timeZone: meta.timeZone)

        let expectedData = try Data(
            contentsOf: tmpRoot.appendingPathComponent("expected.json"))
        let expected = try JSONDecoder().decode(
            ClaudeCodeStats.Result.self, from: expectedData)

        XCTAssertEqual(actual, expected)
    }

    /// Empty root → all zeros, no crash. Mirrors the
    /// "first launch, Claude Code never run" case where neither cache
    /// nor `projects/` exists yet.
    func testEmptyRootReturnsZeroes() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-stats-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }

        let r = ClaudeCodeStats.aggregate(
            claudeRoot: empty,
            today: Date(timeIntervalSince1970: 1_734_912_000),  // 2024-12-23
            timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertEqual(r.totalSessions, 0)
        XCTAssertEqual(r.totalMessages, 0)
        XCTAssertEqual(r.activeDays, 0)
        XCTAssertNil(r.firstSessionDate)
        XCTAssertNil(r.lastSessionDate)
        XCTAssertNil(r.peakActivityHour)
        XCTAssertEqual(r.streaks, .init(currentStreak: 0, longestStreak: 0))
        XCTAssertTrue(r.dailyActivity.isEmpty)
        XCTAssertTrue(r.dailyModelTokens.isEmpty)
        XCTAssertTrue(r.modelUsage.isEmpty)
    }

    /// When the cache is present but no JSONLs have a fresh mtime, the
    /// aggregator returns the cache values straight through.
    func testCacheOnlyWhenNoFreshJsonl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-stats-cacheonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let cache: [String: Any] = [
            "lastComputedDate": "2026-05-18",
            "totalSessions": 100,
            "totalMessages": 4242,
            "firstSessionDate": "2025-12-23T17:03:48.214Z",
            "dailyActivity": [
                ["date": "2026-05-01", "messageCount": 10, "sessionCount": 1, "toolCallCount": 3],
                ["date": "2026-05-02", "messageCount": 20, "sessionCount": 2, "toolCallCount": 5],
            ],
            "dailyModelTokens": [
                [
                    "date": "2026-05-01",
                    "tokensByModel": ["claude-opus-4-7": 1234],
                ]
            ],
            "modelUsage": [
                "claude-opus-4-7": [
                    "inputTokens": 1000,
                    "outputTokens": 2000,
                    "cacheReadInputTokens": 3000,
                    "cacheCreationInputTokens": 4000,
                ]
            ],
            "hourCounts": ["9": 5, "14": 12, "23": 2],
        ]
        try JSONSerialization
            .data(withJSONObject: cache, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("stats-cache.json"))

        let r = ClaudeCodeStats.aggregate(
            claudeRoot: root,
            today: dateForDay(2026, 5, 23, hour: 12),
            timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertEqual(r.totalSessions, 100)
        XCTAssertEqual(r.totalMessages, 4242)
        XCTAssertEqual(r.activeDays, 2)
        XCTAssertEqual(r.firstSessionDate, "2025-12-23T17:03:48.214Z")
        XCTAssertNil(r.lastSessionDate, "lastSessionDate has no cache field; only fresh scans set it")
        XCTAssertEqual(r.peakActivityHour, 14)  // hourCounts max
        XCTAssertEqual(
            r.modelUsage["claude-opus-4-7"],
            .init(
                inputTokens: 1000, outputTokens: 2000,
                cacheReadInputTokens: 3000, cacheCreationInputTokens: 4000))
        XCTAssertEqual(r.dailyActivity.count, 2)
    }

    /// `streaks.currentStreak` walks today → yesterday → … as long as
    /// each day is in the activity set; `longestStreak` is the
    /// longest run anywhere.
    func testStreaksAcrossGaps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-stats-streak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Activity: 2026-05-01, 02, 03  (run of 3, no streak today)
        //           2026-05-10, 11      (run of 2)
        //           2026-05-21, 22, 23  (run of 3, includes today)
        let cache: [String: Any] = [
            "lastComputedDate": "2026-05-24",
            "totalSessions": 0,
            "totalMessages": 0,
            "dailyActivity": [
                ["date": "2026-05-01", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-02", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-03", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-10", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-11", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-21", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-22", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
                ["date": "2026-05-23", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0],
            ],
            "dailyModelTokens": [],
            "modelUsage": [:],
            "hourCounts": [:],
        ]
        try JSONSerialization
            .data(withJSONObject: cache, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("stats-cache.json"))

        let r = ClaudeCodeStats.aggregate(
            claudeRoot: root,
            today: dateForDay(2026, 5, 23, hour: 12),
            timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertEqual(r.streaks.currentStreak, 3)
        XCTAssertEqual(r.streaks.longestStreak, 3)
    }

    // MARK: - Fixture meta

    private struct Meta: Decodable {
        let referenceToday: String
        let timezone: String
    }

    private func loadMeta(from root: URL) throws -> (today: Date, timeZone: TimeZone) {
        let data = try Data(contentsOf: root.appendingPathComponent("meta.json"))
        let m = try JSONDecoder().decode(Meta.self, from: data)
        guard let tz = TimeZone(identifier: m.timezone) else {
            throw NSError(domain: "ClaudeCodeStatsTests", code: 1)
        }
        let parts = m.referenceToday.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw NSError(domain: "ClaudeCodeStatsTests", code: 2)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = 12
        guard let date = cal.date(from: c) else {
            throw NSError(domain: "ClaudeCodeStatsTests", code: 3)
        }
        return (date, tz)
    }

    private func dateForDay(_ y: Int, _ m: Int, _ d: Int, hour: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = hour
        return cal.date(from: c)!
    }
}
