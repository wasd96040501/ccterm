import Foundation

/// Pure aggregation over Claude Code's on-disk session statistics —
/// the same data the official Claude desktop app surfaces in the
/// "new session" stats panel.
///
/// Mirrors the algorithm reverse-engineered from the desktop bundle
/// (`SNr()` / `dpt()` in `app.asar > .vite/build/index.js`):
///
/// 1. Reads `<root>/stats-cache.json` as a frozen baseline. Every
///    daily / per-model record dated **before** `lastComputedDate + 1d`
///    is taken from the cache as-is.
/// 2. Walks `<root>/projects/<slug>/*.jsonl` and any
///    `<slug>/<sub>/subagents/agent-*.jsonl` whose mtime is on or after
///    `lastComputedDate + 1d` (i.e. files the CLI has touched since the
///    cache was last written) and folds them into the same counters:
///    per-day messages / sessions / tool calls, per-model token totals,
///    hour-of-day activity, current / longest streaks.
///
/// `claudeRoot` defaults to `$CLAUDE_CONFIG_DIR` (with `~` expansion)
/// or `~/.claude`. Production callers can use the bare default; tests
/// pin `today` / `timeZone` for determinism.
enum ClaudeCodeStats {

    struct Result: Codable, Equatable {
        var totalSessions: Int
        var totalMessages: Int
        var activeDays: Int
        var firstSessionDate: String?
        var lastSessionDate: String?
        var peakActivityHour: Int?
        var streaks: Streaks
        var dailyActivity: [DailyActivity]
        var dailyModelTokens: [DailyModelTokens]
        var modelUsage: [String: ModelUsage]
    }

    struct Streaks: Codable, Equatable {
        var currentStreak: Int
        var longestStreak: Int
    }

    struct DailyActivity: Codable, Equatable {
        var date: String
        var messageCount: Int
        var sessionCount: Int
        var toolCallCount: Int
    }

    struct DailyModelTokens: Codable, Equatable {
        var date: String
        var tokensByModel: [String: Int]
    }

    struct ModelUsage: Codable, Equatable {
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadInputTokens: Int
        var cacheCreationInputTokens: Int

        static let zero = ModelUsage(
            inputTokens: 0, outputTokens: 0,
            cacheReadInputTokens: 0, cacheCreationInputTokens: 0)
    }

    /// `$CLAUDE_CONFIG_DIR` (with `~` expansion) or `~/.claude`.
    static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
            !env.isEmpty
        {
            let expanded = NSString(string: env).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static func aggregate(
        claudeRoot: URL = defaultRoot,
        today: Date = Date(),
        timeZone: TimeZone = .current,
        windowDays: Int = 182
    ) -> Result {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let cache = readCache(at: claudeRoot.appendingPathComponent("stats-cache.json"))

        let cutoffDay: String
        if let last = cache?.lastComputedDate {
            cutoffDay = addingOneDay(last)
        } else {
            let windowStart = today.addingTimeInterval(-Double(windowDays) * 86_400)
            cutoffDay = dayString(windowStart, in: calendar)
        }
        let cutoffStart = parseDayStart(cutoffDay, calendar: calendar) ?? .distantPast

        var daily: [String: DailyActivity] = [:]
        var dailyTokens: [String: [String: Int]] = [:]
        var modelUsage: [String: ModelUsage] = [:]
        var hourCounts: [Int: Int] = [:]
        var totalSessions = 0
        var totalMessages = 0
        var firstSessionDate: String?
        var lastSessionDate: String?

        if let cache {
            totalSessions = cache.totalSessions ?? 0
            totalMessages = cache.totalMessages ?? 0
            firstSessionDate = cache.firstSessionDate
            for d in cache.dailyActivity ?? [] where d.date < cutoffDay {
                daily[d.date] = d
            }
            for d in cache.dailyModelTokens ?? [] where d.date < cutoffDay {
                dailyTokens[d.date] = d.tokensByModel
            }
            for (model, usage) in cache.modelUsage ?? [:] {
                modelUsage[model] = ModelUsage(
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0,
                    cacheReadInputTokens: usage.cacheReadInputTokens ?? 0,
                    cacheCreationInputTokens: usage.cacheCreationInputTokens ?? 0)
            }
            for (hStr, n) in cache.hourCounts ?? [:] {
                if let h = Int(hStr) { hourCounts[h] = n }
            }
        }

        let transcripts = enumerateTranscripts(
            under: claudeRoot.appendingPathComponent("projects"))
        let fresh = transcripts.filter { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            return mtime >= cutoffStart
        }

        for url in fresh {
            let entries = readJsonl(at: url)
            let ua = entries.filter { $0.type == "user" || $0.type == "assistant" }
            if ua.isEmpty { continue }
            let isSubagent = url.path.contains("/subagents/")
            let filtered = isSubagent ? ua : ua.filter { !$0.isSidechain }
            if filtered.isEmpty { continue }
            guard let firstTs = filtered[0].timestamp,
                let firstDate = parseISO(firstTs)
            else { continue }
            let day = dayString(firstDate, in: calendar)
            if day < cutoffDay { continue }

            var bucket =
                daily[day]
                ?? DailyActivity(
                    date: day, messageCount: 0, sessionCount: 0, toolCallCount: 0)
            if !isSubagent {
                totalSessions += 1
                totalMessages += filtered.count
                bucket.sessionCount += 1
                bucket.messageCount += filtered.count
                let hour = calendar.component(.hour, from: firstDate)
                hourCounts[hour, default: 0] += 1
                if firstSessionDate == nil || firstTs < firstSessionDate! {
                    firstSessionDate = firstTs
                }
                if lastSessionDate == nil || firstTs > lastSessionDate! {
                    lastSessionDate = firstTs
                }
            }
            // SNr: `(!k || r.has(b)) && r.set(b, U)` — subagents never
            // create a new day-bucket, but can increment counters on an
            // existing day. Counters update in-place via the rewrite
            // below.
            if !isSubagent || daily[day] != nil {
                daily[day] = bucket
            }

            for entry in filtered where entry.type == "assistant" {
                let toolUses = entry.contentItems.lazy.filter { $0.type == "tool_use" }
                    .count
                if toolUses > 0, var d = daily[day] {
                    d.toolCallCount += toolUses
                    daily[day] = d
                }
                guard let usage = entry.messageUsage else { continue }
                let model = entry.messageModel ?? "unknown"
                if model == "<synthetic>" { continue }
                var mu = modelUsage[model] ?? .zero
                mu.inputTokens += usage.inputTokens ?? 0
                mu.outputTokens += usage.outputTokens ?? 0
                mu.cacheReadInputTokens += usage.cacheReadInputTokens ?? 0
                mu.cacheCreationInputTokens += usage.cacheCreationInputTokens ?? 0
                modelUsage[model] = mu
                let total = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
                if total > 0 {
                    var tk = dailyTokens[day] ?? [:]
                    tk[model, default: 0] += total
                    dailyTokens[day] = tk
                }
            }
        }

        let sortedDaily = daily.values.sorted { $0.date < $1.date }
        let sortedTokens =
            dailyTokens
            .map { DailyModelTokens(date: $0.key, tokensByModel: $0.value) }
            .sorted { $0.date < $1.date }
        let activeDays = Set(sortedDaily.map { $0.date }).count

        var peakHour: Int?
        var peakCount = 0
        for (h, n) in hourCounts where n > peakCount {
            peakCount = n
            peakHour = h
        }

        let streaks = computeStreaks(
            dates: Set(sortedDaily.map { $0.date }), today: today, calendar: calendar)

        return Result(
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            activeDays: activeDays,
            firstSessionDate: firstSessionDate,
            lastSessionDate: lastSessionDate,
            peakActivityHour: peakHour,
            streaks: streaks,
            dailyActivity: sortedDaily,
            dailyModelTokens: sortedTokens,
            modelUsage: modelUsage)
    }

    // MARK: - Cache file

    /// Subset of `stats-cache.json` that desktop actually consumes —
    /// `longestSession` and `totalSpeculationTimeSavedMs` are present on
    /// disk but ignored.
    private struct CachePayload: Decodable {
        var lastComputedDate: String?
        var dailyActivity: [DailyActivity]?
        var dailyModelTokens: [DailyModelTokens]?
        var modelUsage: [String: CacheModelUsage]?
        var totalSessions: Int?
        var totalMessages: Int?
        var firstSessionDate: String?
        var hourCounts: [String: Int]?
    }

    private struct CacheModelUsage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?
    }

    private static func readCache(at url: URL) -> CachePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    // MARK: - Transcript enumeration

    private static func enumerateTranscripts(under projectsRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard
            let slugs = try? fm.contentsOfDirectory(
                at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var out: [URL] = []
        for slug in slugs {
            let isDir =
                (try? slug.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if !isDir { continue }
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: slug, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for entry in entries {
                let isEntryDir =
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isEntryDir {
                    let subagents = entry.appendingPathComponent(
                        "subagents", isDirectory: true)
                    if let agentFiles = try? fm.contentsOfDirectory(
                        at: subagents, includingPropertiesForKeys: nil)
                    {
                        for f in agentFiles
                        where f.pathExtension == "jsonl"
                            && f.lastPathComponent.hasPrefix("agent-")
                        {
                            out.append(f)
                        }
                    }
                } else if entry.pathExtension == "jsonl" {
                    out.append(entry)
                }
            }
        }
        return out
    }

    // MARK: - JSONL entry shape

    private struct Entry {
        let type: String
        let timestamp: String?
        let isSidechain: Bool
        let messageModel: String?
        let messageUsage: Usage?
        let contentItems: [ContentItem]
    }

    private struct ContentItem {
        let type: String
    }

    private struct Usage {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }

    private static func readJsonl(at url: URL) -> [Entry] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for line in raw.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if let entry = decodeEntry(from: Substring(line)) {
                out.append(entry)
            }
        }
        return out
    }

    private static func decodeEntry(from line: Substring) -> Entry? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? String ?? ""
        let timestamp = obj["timestamp"] as? String
        let isSidechain = obj["isSidechain"] as? Bool ?? false
        let msg = obj["message"] as? [String: Any]
        let model = msg?["model"] as? String

        var usage: Usage?
        if let u = msg?["usage"] as? [String: Any] {
            usage = Usage(
                inputTokens: intValue(u["input_tokens"]),
                outputTokens: intValue(u["output_tokens"]),
                cacheReadInputTokens: intValue(u["cache_read_input_tokens"]),
                cacheCreationInputTokens: intValue(u["cache_creation_input_tokens"]))
        }

        var items: [ContentItem] = []
        if let content = msg?["content"] as? [[String: Any]] {
            items = content.compactMap { c in
                (c["type"] as? String).map(ContentItem.init)
            }
        }

        return Entry(
            type: type, timestamp: timestamp, isSidechain: isSidechain,
            messageModel: model, messageUsage: usage, contentItems: items)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: - Date helpers

    /// ISO8601 with optional fractional seconds — the CLI sometimes
    /// writes `2025-12-23T17:03:48.214Z`, sometimes `…:48Z`.
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ s: String) -> Date? {
        isoWithFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func dayString(_ date: Date, in calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func parseDayStart(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        return calendar.date(from: c)
    }

    private static func addingOneDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return day }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        // Use UTC for arithmetic so the cutoff-day string is stable
        // regardless of caller's timezone — same date math as JS
        // `voA(new Date(...+1d))` does on a local Date.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: c),
            let plus = cal.date(byAdding: .day, value: 1, to: base)
        else { return day }
        let comp = cal.dateComponents([.year, .month, .day], from: plus)
        return String(
            format: "%04d-%02d-%02d", comp.year ?? 0, comp.month ?? 0, comp.day ?? 0)
    }

    private static func computeStreaks(
        dates: Set<String>, today: Date, calendar: Calendar
    ) -> Streaks {
        if dates.isEmpty { return Streaks(currentStreak: 0, longestStreak: 0) }
        var current = 0
        var cursor = today
        while dates.contains(dayString(cursor, in: calendar)) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { break }
            cursor = prev
        }
        let sorted = dates.sorted()
        var longest = 1
        var run = 1
        for i in 1..<sorted.count {
            guard let a = parseDayStart(sorted[i - 1], calendar: calendar),
                let b = parseDayStart(sorted[i], calendar: calendar)
            else { continue }
            let gap = calendar.dateComponents([.day], from: a, to: b).day ?? 0
            if gap == 1 {
                run += 1
            } else {
                longest = max(longest, run)
                run = 1
            }
        }
        longest = max(longest, run)
        return Streaks(currentStreak: current, longestStreak: longest)
    }
}
