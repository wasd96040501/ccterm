import AgentSDK
import Foundation

/// `MessageEntry` → `[Block]` 转换。纯函数,可在任意线程跑。
///
/// 设计要点:
/// - **稳定 id**:每条 Block / ToolGroupBlock.Child 的 UUID 由
///   `(entryId, role, idx...)` 派生(`StableBlockID`)。同一条 entry 跨
///   状态变化(`.localUser` → `.remote.user`、tool_result 回填、group items
///   增长)产同样 id → Coordinator 的 `.update` 路径直接替换 kind,保住
///   fold-state / selection / animation 等 row-local 状态。
/// - **assistant entry 内 text vs tool 顺序**:跟着 `Message2Assistant.message?.content`
///   原始顺序走。text blocks 连续 buffer 成一段 markdown,遇到 tool_use 时
///   先 flush markdown 段,再以单 child 形式产出一个 toolGroup,然后继续。
/// - **GroupEntry**:多个 item 的 tool_uses 聚合成一个 toolGroup,title 取
///   `completedTitle`。
///
/// `unknown` / `thinking` block 跳过,不产 Block。
enum MessageEntryBlockBuilder {

    /// 批量入口。用于 `loadInitial`(reset),内部走 `entryBlocks` 各 entry
    /// 一次,再合并 — 保证「一条 entry 算出的 blocks 在批量和增量两条路径
    /// 上完全一致」(没有合并阶段才会做的额外计算)。
    static func blocks(from entries: [MessageEntry]) -> [Block] {
        var out: [Block] = []
        for entry in entries { out.append(contentsOf: entryBlocks(entry)) }
        return out
    }

    /// 单条 entry → 0..N blocks。bridge 的增量路径(append / prepend / mutate)
    /// 直接调本方法,把 entry 翻译成精确的 Block 列表交给 controller。
    static func entryBlocks(_ entry: MessageEntry) -> [Block] {
        switch entry {
        case .single(let s):
            return singleBlocks(s)
        case .group(let g):
            return makeGroupBlock(g).map { [$0] } ?? []
        }
    }

    // MARK: - Single

    private static func singleBlocks(_ single: SingleEntry) -> [Block] {
        switch single.payload {
        case .localUser(let local):
            guard let text = local.text, !text.isEmpty else { return [] }
            return [Block(
                id: userBubbleBlockId(entryId: single.id),
                kind: .userBubble(text: text))]

        case .remote(let m):
            switch m {
            case .user(let u): return remoteUserBlocks(u, single: single)
            case .assistant(let a): return assistantBlocks(a, single: single)
            default: return []
            }
        }
    }

    private static func remoteUserBlocks(_ user: Message2User,
                                         single: SingleEntry) -> [Block] {
        guard let content = user.message?.content else { return [] }
        let text: String
        switch content {
        case .string(let s):
            text = s
        case .array(let items):
            // 过滤掉 tool_result item(已经被合并到对应 assistant 的 toolGroup);
            // 剩下的 text item 拼成一段 userBubble。
            text = items.compactMap { item -> String? in
                if case .text(let t) = item, let s = t.text, !s.isEmpty { return s }
                return nil
            }.joined(separator: "\n\n")
        case .other:
            return []
        }
        guard !text.isEmpty else { return [] }
        return [Block(
            id: userBubbleBlockId(entryId: single.id),
            kind: .userBubble(text: text))]
    }

    /// User bubble block id 在 `.localUser → .remote.user` 转换前后必须保持
    /// 一致 —— `confirm` 走的是 `.update(id, newKind)`,id 变了就退化成
    /// remove + insert,会把动画/选区抹平。
    private static func userBubbleBlockId(entryId: UUID) -> UUID {
        StableBlockID.derive("entry", entryId.uuidString, "userBubble")
    }

    private static func assistantBlocks(_ assistant: Message2Assistant,
                                        single: SingleEntry) -> [Block] {
        guard let blocks = assistant.message?.content else { return [] }

        var out: [Block] = []
        var textBuffer: [String] = []
        var textStartIdx: Int = 0

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            let source = textBuffer.joined(separator: "\n\n")
            textBuffer.removeAll(keepingCapacity: true)
            let prefix = "entry|\(single.id.uuidString)|md\(textStartIdx)"
            out.append(contentsOf: MarkdownToBlocks.blocks(source: source, idPrefix: prefix))
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .text(let t):
                if let s = t.text, !s.isEmpty {
                    if textBuffer.isEmpty { textStartIdx = idx }
                    textBuffer.append(s)
                }
            case .toolUse(let tu):
                flushText()
                // ToolUse.id 是 Optional<String> —— CLI 上游对每条 tool_use
                // 都填了 id,nil 仅出现在脏数据。fallback 用 `tu|<idx>` 保证
                // 仍能 derive 出稳定的 child id;result 查表用 nil(找不到)。
                let toolUseId = tu.id ?? "tu|\(single.id.uuidString)|\(idx)"
                let result = tu.id.flatMap { single.toolResults[$0] }
                let child = ToolUseToChild.make(
                    toolUse: tu,
                    toolUseId: toolUseId,
                    result: result)
                let title = ToolGroupTitleBuilder.singleTitle(
                    toolUse: tu, hasResult: result != nil)
                let group = ToolGroupBlock(title: title, children: [child])
                let blockId = StableBlockID.derive(
                    "entry", single.id.uuidString, "tg", String(idx))
                out.append(Block(id: blockId, kind: .toolGroup(group)))
            case .thinking, .unknown:
                continue
            }
        }
        flushText()
        return out
    }

    // MARK: - Group

    private static func makeGroupBlock(_ group: GroupEntry) -> Block? {
        var children: [ToolGroupBlock.Child] = []
        for (itemIdx, item) in group.items.enumerated() {
            guard case .remote(let m) = item.payload,
                  case .assistant(let a) = m,
                  let blocks = a.message?.content else { continue }
            for (blockIdx, block) in blocks.enumerated() {
                guard case .toolUse(let tu) = block else { continue }
                let toolUseId = tu.id
                    ?? "tu|\(group.id.uuidString)|\(itemIdx)|\(blockIdx)"
                let result = tu.id.flatMap { item.toolResults[$0] }
                children.append(ToolUseToChild.make(
                    toolUse: tu,
                    toolUseId: toolUseId,
                    result: result))
            }
        }
        guard !children.isEmpty else { return nil }
        return Block(
            id: StableBlockID.derive("group", group.id.uuidString),
            kind: .toolGroup(ToolGroupBlock(title: group.completedTitle, children: children)))
    }
}

/// 单个 tool_use 包成 toolGroup 时使用的 title 文案。跟老 ToolBlock 的
/// header 文案逻辑对齐:running 用 activeFragment,完成用 completedFragment。
enum ToolGroupTitleBuilder {
    static func singleTitle(toolUse: ToolUse, hasResult: Bool) -> String {
        if hasResult, let s = toolUse.completedFragment { return s }
        if !hasResult, let s = toolUse.activeFragment { return s }
        return toolUse.caseName
    }
}
