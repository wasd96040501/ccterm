import Foundation
import AgentSDK

// MARK: - JSONL path resolution

extension SessionHandle2 {

    /// Claude CLI 的 live JSONL 目录（`~/.claude/projects/<slug>/<sessionId>.jsonl`）。
    nonisolated static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// CCTerm 自建的 export JSONL 目录（含完整 stdio 消息）。优先使用。
    nonisolated static var exportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ccterm/export")
    }

    /// 本 session 的历史 JSONL URL。export 优先；不存在则回落到 live；再不存在则 nil。
    /// slug 需要 repository 里的 cwd，所以 `activate()` 之前 resume 也能拿到。
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

    /// 两段式历史加载：
    /// 1. **Phase A**：`JSONLTailReader` 字节级读末尾 ~80 行，forward-parse，receive
    ///    进 messages → `.tailLoaded(count)`。典型 < 50 ms，UI 可以立刻渲染末屏。
    /// 2. **Phase B**：后台 parse `[0, tailStartByteOffset)` prefix，主线程 prepend
    ///    到 messages 头部 + 用 prefix 的 tool_use index 回填 tail 中遗留的
    ///    unresolved tool_results → `.loaded`。
    ///
    /// live 追加在 Phase B 期间自由 append 到 messages 尾部；Phase B 用 prepend
    /// 操作不动 suffix —— live 不会被吞掉。
    ///
    /// 幂等：`.loadingTail` / `.tailLoaded` / `.loaded` 直接返回；`.failed` 视为重试。
    /// 与 `activate()` 完全正交——stopped / notStarted session 也能查看历史。
    ///
    /// - Parameter url: 可选路径覆盖，仅测试使用；生产代码调 `loadHistory()` 走默认解析。
    /// - Parameter tailTarget: Phase A 目标行数。默认 80 对典型 viewport 够用。
    func loadHistory(overrideURL url: URL? = nil, tailTarget: Int = 80) {
        switch historyLoadState {
        case .loadingTail, .tailLoaded:
            return
        case .loaded:
            // 已加载过（用户切走后再切回）—— 重新 emit `.initialPaint`，view 层按
            // 首次打开语义 re-paint。带上 `savedScrollAnchor`：view 若能找到
            // 匹配 stableId 则围绕 anchor 展开并恢复位置（对齐 Telegram
            // `ChatInterfaceHistoryScrollState` + `.positionRestoration`）；
            // 找不到则自然 fallback 到 tail + `.bottom`。
            emitSnapshot(.initialPaint, scrollHint: savedScrollAnchor)
            return
        case .failed:
            historyLoadState = .notLoaded
        case .notLoaded:
            break
        }
        historyLoadState = .loadingTail

        let resolved = url ?? historyJSONLURL
        appLog(.info, "SessionHandle2",
            "loadHistory begin \(sessionId) url=\(resolved?.path ?? "(none)") tailTarget=\(tailTarget)")

        Task.detached {
            // ── Phase A: tail ────────────────────────────────────────────
            let tailResult = Self.parseTail(at: resolved, targetLines: tailTarget)
            var tailEndOffset = 0
            switch tailResult {
            case .failure(let err):
                await MainActor.run { [weak self] in
                    self?.historyLoadState = .failed(err.localizedDescription)
                    appLog(.warning, "SessionHandle2",
                        "loadHistory FAILED(tail) \(self?.sessionId ?? "?") err=\(err.localizedDescription)")
                }
                return
            case .success(let parsed):
                tailEndOffset = parsed.tailStartByteOffset
                let t0 = CFAbsoluteTimeGetCurrent()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for m in parsed.messages { self.receive(m, mode: .replay) }
                    let count = parsed.messages.count
                    self.historyLoadState = .tailLoaded(count: count)
                    // Phase A 批量 ingest 完毕 → 首帧意图。哪怕 messages 为空
                    // (session 没有任何可渲染消息) 也要发一次,让视图从 .idle
                    // 翻到 initialPaint 对应的渲染分支。
                    self.emitSnapshot(.initialPaint)
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    appLog(.info, "SessionHandle2",
                        "loadHistory tail done \(self.sessionId) count=\(count) ingest=\(ms)ms")
                }
            }

            // ── Phase B: prefix ─────────────────────────────────────────
            // tailEndOffset = 0 表示 tail 已覆盖全文件，无需 Phase B。
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
                // Phase B 失败不 downgrade — tail 已经可见。只 warning。
                await MainActor.run { [weak self] in
                    appLog(.warning, "SessionHandle2",
                        "loadHistory PREFIX_FAIL \(self?.sessionId ?? "?") err=\(err.localizedDescription) — keeping tailLoaded")
                }
                return
            case .success(let prefix):
                let t0 = CFAbsoluteTimeGetCurrent()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Phase B 的 tailBaseline = 当前 messages.count（含 Phase A 的 tail
                    // + Phase B 跑期间 live 追加的）。prepend 完成后 tail 区间的起点
                    // 变成 prefixEntries.count。
                    let tailBaseline = self.messages.count

                    // 1. 先把 prefix 喂进一个临时 receive 通道：借用现有 append 逻辑，
                    //    但插到头部。最简单：收集 prefix 的 MessageEntry，然后一次 insert。
                    let prefixEntries = Self.buildEntries(from: prefix)
                    if !prefixEntries.isEmpty {
                        self.messages.insert(contentsOf: prefixEntries, at: 0)
                    }
                    let prefixCount = prefixEntries.count
                    let newTailStart = prefixCount
                    let absoluteTailEnd = newTailStart + tailBaseline

                    // 2. 用 prefix + tail 所有 tool_use 建 index,回填 tail 里
                    //    unresolved tool_results。
                    let allForIndex: [Message2] = prefix + self.tailMessagesAsArray(
                        from: newTailStart, until: absoluteTailEnd)
                    let index = ToolResultReresolver.buildToolUseIndex(from: allForIndex)
                    let updatedIdx = ToolResultReresolver.applyResolution(
                        to: &self.messages, from: newTailStart, using: index)

                    self.historyLoadState = .loaded
                    // Phase B 完成 → emit 前插意图(哪怕 prefix 为空也要发:
                    // tool_result reresolve 也算 update)。
                    if prefixCount > 0 {
                        self.emitSnapshot(.prependHistory)
                    } else if !updatedIdx.isEmpty {
                        self.emitSnapshot(.update)
                    }
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    appLog(.info, "SessionHandle2",
                        "loadHistory full done \(self.sessionId) prefix=\(prefixCount) "
                        + "tailReresolved=\(updatedIdx.count) merge=\(ms)ms")
                }
            }
        }
    }

    // MARK: - Phase A/B parsers

    struct TailParsed {
        let messages: [Message2]
        let tailStartByteOffset: Int
    }

    /// Phase A: 字节 tail + forward parse + per-file `Message2Resolver`。
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
            return .success(TailParsed(
                messages: msgs,
                tailStartByteOffset: readerResult.tailStartByteOffset))
        } catch {
            return .failure(error)
        }
    }

    /// Phase B: 读 `[0, byteLimit)` 解析为 prefix Message2 列表。独立 resolver。
    /// 如果 prefix 内 tool_use 能 cover tail 的 unresolved tool_result，回填阶段
    /// 再统一处理。
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

    /// 兼容入口：旧测试沿用。把整个文件 parse 成 `[Message2]`（无 tail/prefix
    /// 分离）。保留给 unit tests。生产代码走两段式。
    nonisolated static func parseJSONL(at url: URL?) -> Result<[Message2], Error> {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return .success([])
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(HistoryParseError.invalidUTF8)
            }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return .success(parseLines(lines))
        } catch {
            return .failure(error)
        }
    }

    /// 把 JSONL 文本行数组 forward parse 成 `[Message2]`，丢掉解析失败的行。
    nonisolated static func parseLines(_ lines: [String]) -> [Message2] {
        let resolver = Message2Resolver()
        var out: [Message2] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = try? resolver.resolve(json) else {
                continue
            }
            out.append(msg)
        }
        return out
    }

    /// 把 parse 出来的 prefix `[Message2]` 走一遍 `receive(...)` 的 filter 逻辑，
    /// 收集成 `[MessageEntry]`（给 Phase B prepend 用）。
    ///
    /// 复用 `receive(_:mode:.replay)` 的 timeline 写入规则就意味着要做一次"影子
    /// handle"—— 过于重。简化：prefix 只做 minimum 转换（single + group），不分
    /// lifecycle / hasUnread。这里选用一个专用 session-temp handle 跑一次转换。
    @MainActor
    fileprivate static func buildEntries(from messages: [Message2]) -> [MessageEntry] {
        // 为避免与真实 handle 的 state 纠缠，用 inMemory SessionRepository 建一个
        // 临时 handle，跑 receive 获得 entries，再提取出来。
        let repo = SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
        let tmp = SessionHandle2(sessionId: "prefix-builder-\(UUID().uuidString)", repository: repo)
        tmp.skipBootstrapForTesting = true
        for m in messages { tmp.receive(m, mode: .replay) }
        return tmp.messages
    }

    /// 把 self.messages 在 `[start, end)` 区间的 remote Message2 挖出来，供
    /// Phase B 的 tool_use index 构建使用。
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
}
