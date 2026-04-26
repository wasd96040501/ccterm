import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// 关键不变量验证 —— GroupComponent + GroupChildDispatch 的对外行为:
///
/// 1. **三态 title**:`(active, collapsed)` / `(active, expanded)` / `(completed, *)`
///    分别选用 progressive-brief / aggregated-active / aggregated-completed,
///    切换 `isExpanded` 在 active group 上必然换 title 字符串。
/// 2. **Child dispatch 按 kind**:Read 走 `.read(...)` 富化(高度 = group header),
///    其它 tool 走 `.placeholder(...)` 兜底(高度 = placeholder)。
/// 3. **展开 / 折叠几何**:折叠态 row 高度 = header + 上下 padding;展开态多
///    出 N 条 child + spacing,childFrames 数与 toolUses 一致,且 frame y
///    单调递增不重叠。
@MainActor
final class GroupComponentTests: XCTestCase {

    private let theme = TranscriptTheme(markdown: .default)

    // MARK: - 三态 title

    func testGroupComponent_pickTitleByActiveAndExpanded() {
        // 构造一个混合 kind 的 group:Read x2 + Bash x1。
        let entry = makeGroupEntry(tools: [
            makeReadToolUse(id: "r1", filePath: "/x/Alpha.swift"),
            makeReadToolUse(id: "r2", filePath: "/x/Beta.swift"),
            makeBashToolUse(id: "b1", description: "build"),
        ])

        // active = entryIndex 是最后一条
        let activeInputs = GroupComponent.inputs(from: entry, entryIndex: 0, entryCount: 1)
        XCTAssertEqual(activeInputs.count, 1)
        let activeContent = GroupComponent.prepare(activeInputs[0].input, theme: theme)
        // (active, collapsed) → activeBrief = 最后一个 tool 的 progressive。
        XCTAssertEqual(
            activeContent.pickTitle(isExpanded: false).text,
            String(localized: "Running: \("build")"))
        // (active, expanded) → 聚合进行时,first-occurrence 顺序:Read 2,Bash 1。
        XCTAssertEqual(
            activeContent.pickTitle(isExpanded: true).text,
            [
                String(localized: "Reading \(2) files"),
                String(localized: "Running \(1) commands"),
            ].joined(separator: " · "))

        // completed:不论 expanded 与否都是聚合过去时。
        let completedInputs = GroupComponent.inputs(from: entry, entryIndex: 0, entryCount: 2)
        let completedContent = GroupComponent.prepare(completedInputs[0].input, theme: theme)
        let expectedCompleted = [
            String(localized: "Read \(2) files"),
            String(localized: "Ran \(1) commands"),
        ].joined(separator: " · ")
        XCTAssertEqual(completedContent.pickTitle(isExpanded: false).text, expectedCompleted)
        XCTAssertEqual(completedContent.pickTitle(isExpanded: true).text, expectedCompleted)
    }

    // MARK: - Child dispatch

    func testGroupChildDispatch_readBecomesHeaderStyleOthersGetPlaceholder() {
        let entry = makeGroupEntry(tools: [
            makeReadToolUse(id: "r1", filePath: "/x/foo.swift"),
            makeBashToolUse(id: "b1", description: "ls"),
            // 未富化 kind:走 PlaceholderChildRenderer。
            makeTodoWriteToolUse(id: "t1"),
        ])
        let inputs = GroupComponent.inputs(from: entry, entryIndex: 0, entryCount: 1)
        let content = GroupComponent.prepare(inputs[0].input, theme: theme)
        XCTAssertEqual(content.children.count, 3)

        // Read → .read
        guard case .read = content.children[0].content else {
            return XCTFail("Read tool must dispatch to ReadChildRenderer, got \(content.children[0].content)")
        }
        // Bash → .placeholder(兜底)
        guard case .placeholder = content.children[1].content else {
            return XCTFail("Bash tool must fall through to PlaceholderChildRenderer, got \(content.children[1].content)")
        }
        // TodoWrite → .placeholder
        guard case .placeholder = content.children[2].content else {
            return XCTFail("TodoWrite must fall through to PlaceholderChildRenderer, got \(content.children[2].content)")
        }
    }

    // MARK: - 展开 / 折叠 layout

    func testGroupComponent_expandedLayoutGrowsRowAndOrdersChildren() {
        let entry = makeGroupEntry(tools: [
            makeReadToolUse(id: "r1", filePath: "/x/a.swift"),
            makeReadToolUse(id: "r2", filePath: "/x/b.swift"),
            makeBashToolUse(id: "b1", description: "build"),
        ])
        let input = GroupComponent.inputs(from: entry, entryIndex: 0, entryCount: 1)[0].input
        let content = GroupComponent.prepare(input, theme: theme)
        let width: CGFloat = 600

        let collapsed = GroupComponent.layout(
            content, theme: theme, width: width, state: GroupComponent.State(isExpanded: false))
        let expanded = GroupComponent.layout(
            content, theme: theme, width: width, state: GroupComponent.State(isExpanded: true))

        // 折叠态:无 child frame。
        XCTAssertTrue(collapsed.childFrames.isEmpty)
        // 展开态:每个 tool_use 一个 child frame。
        XCTAssertEqual(expanded.childFrames.count, 3)

        // 展开必然变高(至少多出 N×childHeight + spacing)。
        XCTAssertGreaterThan(expanded.cachedHeight, collapsed.cachedHeight)

        // child frames 单调递增(y 严格非降),不重叠 —— 邻居 minY ≥ 上一个 maxY。
        var lastMaxY: CGFloat = .leastNormalMagnitude
        for frame in expanded.childFrames {
            let rect = childFrameRect(frame)
            XCTAssertGreaterThanOrEqual(rect.minY, lastMaxY,
                "child frames must not overlap (got minY=\(rect.minY) after maxY=\(lastMaxY))")
            lastMaxY = rect.maxY
        }

        // relayouted 快路径:isExpanded 翻转时返回非 nil 且 cachedHeight 更新。
        let fast = GroupComponent.relayouted(
            collapsed, theme: theme, state: GroupComponent.State(isExpanded: true))
        XCTAssertNotNil(fast, "relayouted must produce a fast-path layout when isExpanded toggles")
        XCTAssertEqual(fast?.cachedHeight, expanded.cachedHeight)
        // 同 state 重入 → 返回原 layout(no-op)。
        let same = GroupComponent.relayouted(
            collapsed, theme: theme, state: GroupComponent.State(isExpanded: false))
        XCTAssertEqual(same?.cachedHeight, collapsed.cachedHeight)
    }

    // MARK: - Helpers

    private func childFrameRect(_ frame: GroupChildFrame) -> CGRect {
        switch frame {
        case .read(let f):        return f.rect
        case .placeholder(let f): return f.rect
        }
    }

    private func makeGroupEntry(tools: [Message2]) -> MessageEntry {
        let items = tools.map { msg in
            SingleEntry(id: UUID(), payload: .remote(msg), delivery: nil, toolResults: [:])
        }
        return .group(GroupEntry(id: UUID(), items: items))
    }

    private func makeReadToolUse(id: String, filePath: String) -> Message2 {
        resolve([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": id,
                    "name": "Read",
                    "input": ["file_path": filePath],
                ]],
            ],
        ])
    }

    private func makeBashToolUse(id: String, description: String) -> Message2 {
        resolve([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": id,
                    "name": "Bash",
                    "input": ["command": "true", "description": description],
                ]],
            ],
        ])
    }

    private func makeTodoWriteToolUse(id: String) -> Message2 {
        resolve([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": id,
                    "name": "TodoWrite",
                    "input": ["todos": []],
                ]],
            ],
        ])
    }

    private func resolve(_ json: [String: Any]) -> Message2 {
        (try? Message2Resolver().resolve(json)) ?? .unknown(name: "factory-failed", raw: json)
    }
}
