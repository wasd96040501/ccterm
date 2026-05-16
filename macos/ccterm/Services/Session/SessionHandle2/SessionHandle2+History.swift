import AgentSDK
import Foundation

// MARK: - JSONL path resolution

extension SessionHandle2 {

    /// Claude CLI's live JSONL directory
    /// (`~/.claude/projects/<slug>/<sessionId>.jsonl`).
    nonisolated static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// CCTerm's own export JSONL directory (contains the full stdio stream).
    /// Preferred over the live file.
    nonisolated static var exportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ccterm/export")
    }

    /// History JSONL URL for this session. Export takes priority, then falls
    /// back to live, otherwise nil. Slug derives from the repository's cwd,
    /// so even resume before `activate()` can locate it.
    var historyJSONLURL: URL? {
        let export = Self.exportRoot.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: export.path) { return export }

        guard let rec = repository.find(sessionId), let slug = rec.slug else { return nil }
        let live = Self.claudeProjectsRoot
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: live.path) ? live : nil
    }
}

// MARK: - loadHistory

extension SessionHandle2 {

    /// Two-phase history load:
    /// 1. **Phase A**: `JSONLTailReader` does a byte-level read of the last
    ///    ~80 lines, forward-parses, receives into messages →
    ///    `.tailLoaded(count)`. Typically < 50 ms, so the UI can render the
    ///    tail immediately.
    /// 2. **Phase B**: parse `[0, tailStartByteOffset)` in the background,
    ///    prepend to the head of messages on the main thread, and use the
    ///    prefix's tool_use index to backfill any unresolved tool_results in
    ///    the tail → `.loaded`.
    ///
    /// Live appends to the tail during Phase B continue freely; Phase B only
    /// prepends, never touching the suffix — live messages are not swallowed.
    ///
    /// Idempotent: `.loadingTail` / `.tailLoaded` / `.loaded` return
    /// immediately; `.failed` retries. Fully orthogonal to `activate()` —
    /// stopped / notStarted sessions can still view history.
    ///
    /// - Parameter url: Optional path override, test-only; production code
    ///   calls `loadHistory()` for default resolution.
    /// - Parameter tailTarget: Phase A target line count. 80 covers typical
    ///   viewports.
    func loadHistory(overrideURL url: URL? = nil, tailTarget: Int = 80) {
        switch historyLoadState {
        case .loadingTail, .tailLoaded:
            return
        case .loaded:
            // Already loaded (user switched away and back) — have the bridge
            // reload everything.
            //
            // Synchronously emitting before the view is mounted is safe:
            // bridge → `controller.loadInitial` has its own pending-cache
            // path that buffers blocks while layoutWidth=0 and consumes them
            // when the coordinator's `onLayoutReady` fires. So this layer
            // doesn't have to care about SwiftUI commit ordering.
            //
            // No precomputed blocks here: the re-entry path is synchronous
            // and we accept the same-frame Markdown parse cost. The slow
            // path is the cold load (Phase A / Phase B), where precompute
            // moves the parse off the main thread.
            onMessagesChange?(.reset(messages, precomputedBlocks: nil))
            return
        case .failed:
            historyLoadState = .notLoaded
        case .notLoaded:
            break
        }
        historyLoadState = .loadingTail

        let resolved = url ?? historyJSONLURL
        appLog(
            .info, "SessionHandle2",
            "loadHistory begin \(sessionId) url=\(resolved?.path ?? "(none)") tailTarget=\(tailTarget)")

        Task.detached {
            // ── Phase A: tail ────────────────────────────────────────────
            let tailResult = Self.parseTail(at: resolved, targetLines: tailTarget)
            var tailEndOffset = 0
            switch tailResult {
            case .failure(let err):
                await MainActor.run { [weak self] in
                    self?.historyLoadState = .failed(err.localizedDescription)
                    appLog(
                        .warning, "SessionHandle2",
                        "loadHistory FAILED(tail) \(self?.sessionId ?? "?") err=\(err.localizedDescription)")
                }
                return
            case .success(let parsed):
                tailEndOffset = parsed.tailStartByteOffset
                let t0 = CFAbsoluteTimeGetCurrent()
                // Hop 1 (main): ingest the parsed Message2s into entries and
                // flip the load state. receive() in replay mode does not
                // fire the sink, so the bridge is still empty at this point.
                let snapshot: [MessageEntry] = await MainActor.run { [weak self] in
                    guard let self else { return [] }
                    for m in parsed.messages { self.receive(m, mode: .replay) }
                    let count = parsed.messages.count
                    self.historyLoadState = .tailLoaded(count: count)
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    appLog(
                        .info, "SessionHandle2",
                        "loadHistory tail ingest done \(self.sessionId) count=\(count) ingest=\(ms)ms")
                    return self.messages
                }
                // Off-main: pre-build the (entry.id → [Block]) map. The
                // dominant cost here is `MarkdownDocument(parsing:)` for
                // assistant text segments — keeping it off the main thread
                // is the whole point of this two-hop dance.
                let t1 = CFAbsoluteTimeGetCurrent()
                let precomputed = MessageEntryBlockBuilder.precompute(snapshot)
                let precomputeMs = Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)
                // Hop 2 (main): hand the precomputed blocks to the bridge.
                // Fire `.reset` even when snapshot is empty so the bridge
                // flips `didLoadInitial = true` and subsequent live
                // appends take the incremental path.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.onMessagesChange?(
                        .reset(snapshot, precomputedBlocks: precomputed))
                    appLog(
                        .info, "SessionHandle2",
                        "loadHistory tail reset fired \(self.sessionId) "
                            + "count=\(snapshot.count) precompute=\(precomputeMs)ms")
                }
            }

            // ── Phase B: prefix ─────────────────────────────────────────
            // tailEndOffset == 0 means the tail covered the whole file —
            // no Phase B needed.
            guard tailEndOffset > 0, let resolved else {
                await MainActor.run { [weak self] in
                    self?.historyLoadState = .loaded
                }
                return
            }
            let prefixResult = Self.parsePrefix(
                at: resolved, byteLimit: tailEndOffset)
            switch prefixResult {
            case .failure(let err):
                // Phase B failure does not downgrade — tail is already
                // visible. Just warn.
                await MainActor.run { [weak self] in
                    appLog(
                        .warning, "SessionHandle2",
                        "loadHistory PREFIX_FAIL \(self?.sessionId ?? "?") err=\(err.localizedDescription) — keeping tailLoaded"
                    )
                }
                return
            case .success(let prefix):
                let t0 = CFAbsoluteTimeGetCurrent()
                // Hop 1 (main): merge the parsed prefix into `messages`,
                // build the tool_use index, re-resolve any tail
                // `tool_result`s whose anchor lives in the prefix, flip
                // `historyLoadState = .loaded`. Capture the prefix entries
                // and the re-resolved entries so hop #2 can fan them out
                // to the bridge after the off-main precompute.
                let snapshot: PhaseBSnapshot = await MainActor.run { [weak self] in
                    guard let self else {
                        return PhaseBSnapshot(prefixEntries: [], updatedEntries: [])
                    }
                    // tailBaseline = current messages.count (Phase A tail
                    // plus any live appends during Phase B). After prepend,
                    // the tail starts at `prefixEntries.count`.
                    let tailBaseline = self.messages.count
                    let prefixEntries = Self.buildEntries(from: prefix)
                    if !prefixEntries.isEmpty {
                        self.messages.insert(contentsOf: prefixEntries, at: 0)
                    }
                    let prefixCount = prefixEntries.count
                    let newTailStart = prefixCount
                    let absoluteTailEnd = newTailStart + tailBaseline
                    let allForIndex: [Message2] =
                        prefix
                        + self.tailMessagesAsArray(
                            from: newTailStart, until: absoluteTailEnd)
                    let index = ToolResultReresolver.buildToolUseIndex(from: allForIndex)
                    let updatedIdx = ToolResultReresolver.applyResolution(
                        to: &self.messages, from: newTailStart, using: index)
                    self.historyLoadState = .loaded
                    let prefixSnapshot =
                        prefixCount > 0
                        ? Array(self.messages.prefix(prefixCount)) : []
                    let updatedSnapshot = updatedIdx.compactMap {
                        idx -> MessageEntry? in
                        self.messages.indices.contains(idx) ? self.messages[idx] : nil
                    }
                    return PhaseBSnapshot(
                        prefixEntries: prefixSnapshot,
                        updatedEntries: updatedSnapshot)
                }
                // Off-main: precompute blocks for the prefix. Same trick as
                // Phase A — Markdown parsing for assistant text segments
                // moves off the main thread.
                let t1 = CFAbsoluteTimeGetCurrent()
                let precomputed = MessageEntryBlockBuilder.precompute(snapshot.prefixEntries)
                let precomputeMs = Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)
                // Hop 2 (main): fan out `.prepended` (with precomputed
                // blocks) + `.updated` for every re-resolved tail entry.
                // Order matters: the bridge recomputes its anchor after
                // prepended, so subsequent updates correctly locate the
                // tail entry.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !snapshot.prefixEntries.isEmpty {
                        self.onMessagesChange?(
                            .prepended(
                                snapshot.prefixEntries,
                                precomputedBlocks: precomputed))
                    }
                    for entry in snapshot.updatedEntries {
                        self.onMessagesChange?(.updated(entry))
                    }
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    appLog(
                        .info, "SessionHandle2",
                        "loadHistory full done \(self.sessionId) prefix=\(snapshot.prefixEntries.count) "
                            + "tailReresolved=\(snapshot.updatedEntries.count) "
                            + "precompute=\(precomputeMs)ms merge=\(ms)ms")
                }
            }
        }
    }

    // MARK: - Phase A/B parsers

    struct TailParsed {
        let messages: [Message2]
        let tailStartByteOffset: Int
    }

    /// Phase A: byte tail + forward parse + per-file `Message2Resolver`.
    nonisolated static func parseTail(
        at url: URL?, targetLines: Int
    ) -> Result<TailParsed, Error> {
        guard let url else {
            return .success(TailParsed(messages: [], tailStartByteOffset: 0))
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            return .success(TailParsed(messages: [], tailStartByteOffset: 0))
        }
        do {
            let readerResult = try JSONLTailReader.readTail(
                url: url, targetLines: targetLines)
            let msgs = parseLines(readerResult.lines)
            return .success(
                TailParsed(
                    messages: msgs,
                    tailStartByteOffset: readerResult.tailStartByteOffset))
        } catch {
            return .failure(error)
        }
    }

    /// Phase B: read `[0, byteLimit)` and parse into a prefix Message2 list,
    /// using its own resolver. If the prefix's tool_use entries can cover any
    /// unresolved tool_results in the tail, the backfill step handles them
    /// together later.
    nonisolated static func parsePrefix(
        at url: URL, byteLimit: Int
    ) -> Result<[Message2], Error> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: byteLimit) ?? Data()
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(HistoryParseError.invalidUTF8)
            }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .success(parseLines(lines))
        } catch {
            return .failure(error)
        }
    }

    /// Forward-parse JSONL text lines into `[Message2]`, dropping lines that
    /// fail to parse.
    nonisolated static func parseLines(_ lines: [String]) -> [Message2] {
        let resolver = Message2Resolver()
        var out: [Message2] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let msg = try? resolver.resolve(json)
            else {
                continue
            }
            out.append(msg)
        }
        return out
    }

    /// Run prefix `[Message2]` through `receive(...)`'s filter logic and
    /// collect the resulting `[MessageEntry]` for Phase B prepend.
    ///
    /// Reusing `receive(_:mode:.replay)`'s timeline write rules implies a
    /// "shadow handle" — too heavy. Simplification: prefix only does the
    /// minimum conversion (single + group), no lifecycle / hasUnread. Here
    /// we spin up a dedicated temp handle and run a single conversion.
    @MainActor
    fileprivate static func buildEntries(from messages: [Message2]) -> [MessageEntry] {
        // Avoid entangling with the real handle's state by building a temp
        // handle on an in-memory SessionRepository, running receive, and
        // extracting the resulting entries.
        let repo = CoreDataSessionRepository(coreDataStack: CoreDataStack(inMemory: true))
        let tmp = SessionHandle2(sessionId: "prefix-builder-\(UUID().uuidString)", repository: repo)
        tmp.skipBootstrapForTesting = true
        for m in messages { tmp.receive(m, mode: .replay) }
        return tmp.messages
    }

    /// Extract remote Message2 entries in `[start, end)` for Phase B's
    /// tool_use index construction.
    @MainActor
    fileprivate func tailMessagesAsArray(from start: Int, until end: Int) -> [Message2] {
        guard start < messages.count else { return [] }
        let clampedEnd = min(end, messages.count)
        var out: [Message2] = []
        for i in start..<clampedEnd {
            switch messages[i] {
            case .single(let s):
                if case .remote(let m) = s.payload { out.append(m) }
            case .group(let g):
                for s in g.items {
                    if case .remote(let m) = s.payload { out.append(m) }
                }
            }
        }
        return out
    }

    enum HistoryParseError: LocalizedError {
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .invalidUTF8: return "History JSONL is not valid UTF-8"
            }
        }
    }

    /// Phase B's first main hop returns this snapshot to the detached
    /// task. `prefixEntries` is what gets `.prepended` to the bridge;
    /// `updatedEntries` are tail entries whose `tool_result` anchors lived
    /// in the prefix and got re-resolved.
    fileprivate struct PhaseBSnapshot {
        let prefixEntries: [MessageEntry]
        let updatedEntries: [MessageEntry]
    }
}
