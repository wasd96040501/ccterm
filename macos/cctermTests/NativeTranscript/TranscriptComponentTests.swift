import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// POC for `TranscriptComponent` 协议及其泛型基础设施
/// (`GenericPreparedItem<C>` + `ComponentRow<C>`)。
///
/// 验证目标(无现有 component 迁移,纯基础设施):
/// 1. Component 声明 4 轴即可 —— 协议能编译、能实例化、能产 Prepared/Layout/Row
/// 2. `GenericPreparedItem<C>` 的 `withStableId` / `strippingLayout` /
///    `cacheKey` 模板替代正确
/// 3. `ComponentRow<C>` 的 width-dispatch 语义:width 不变不重算,width 变
///    重跑 `C.layout(...)` 并写回 cachedHeight/Width
/// 4. Cache 的 `.custom(tag)` variant 不与老三个 case 撞、同 component 的
///    两个不同 contentHash 产不同 key
@MainActor
final class TranscriptComponentTests: XCTestCase {

    private let theme = TranscriptTheme.default

    // MARK: - Cache key

    func testDifferentTagsProduceDifferentKeys() {
        let a = TranscriptPrepareCache.Key(contentHash: 1, tag: "A")
        let b = TranscriptPrepareCache.Key(contentHash: 1, tag: "B")
        XCTAssertNotEqual(a, b)
    }

    func testSameTagAndHashProduceSameKey() {
        let a = TranscriptPrepareCache.Key(contentHash: 42, tag: "X")
        let b = TranscriptPrepareCache.Key(contentHash: 42, tag: "X")
        XCTAssertEqual(a, b)
    }

    // MARK: - GenericPreparedItem templates

    func testGenericPreparedItemHeightFromLayout() {
        let item = makeMockItem(text: "hello", stable: "s1", width: 100)
        XCTAssertEqual(item.cachedHeight, MockComponent.mockHeight(text: "hello"))
    }

    func testGenericPreparedItemHeightZeroWhenLayoutStripped() {
        let item = makeMockItem(text: "hello", stable: "s1", width: 100)
        let stripped = item.strippingLayout()
        XCTAssertEqual(stripped.cachedHeight, 0,
            "stripped item 没 layout → cachedHeight = 0(cache 里按这个存)")
    }

    func testGenericPreparedItemWithStableIdPreservesContent() {
        let item = makeMockItem(text: "hello", stable: "old", width: 100)
        let rebound = item.withStableId("new" as AnyHashable)
        XCTAssertEqual(rebound.stableId, AnyHashable("new"))
        XCTAssertEqual(rebound.contentHash, item.contentHash,
            "contentHash 是 content-only 指纹,换 stableId 不受影响")
        XCTAssertEqual(rebound.cachedHeight, item.cachedHeight,
            "layout 被搬过来 —— cache hit 后直接用,不用重排")
    }

    func testGenericPreparedItemStripThenRestoreViaLayout() {
        let full = makeMockItem(text: "abc", stable: "s1", width: 100)
        let stripped = full.strippingLayout()
        XCTAssertEqual(stripped.cachedHeight, 0)

        // `withStableId` 不影响 layout 状态(仍是 nil)
        let reboundStripped = stripped.withStableId("s2" as AnyHashable)
        XCTAssertEqual(reboundStripped.cachedHeight, 0)
    }

    func testCacheKeyUsesComponentTag() {
        let item = makeMockItem(text: "hello", stable: "s1", width: 100)
        XCTAssertEqual(item.cacheKey.tag, MockComponent.tag)
    }

    // MARK: - ComponentRow dispatch

    func testComponentRowCarriesInitialLayout() {
        let item = makeMockItem(text: "hello", stable: "s1", width: 100)
        let row = item.makeRow(theme: TranscriptTheme(markdown: .default))
        XCTAssertEqual(row.cachedHeight, MockComponent.mockHeight(text: "hello"))
        XCTAssertEqual(row.identifier, MockComponent.tag)
        XCTAssertEqual(row.stableId, AnyHashable("s1"))
    }

    func testComponentRowMakeSizeSkipsIfWidthUnchanged() {
        let row = makeMockRow(text: "hello", stable: "s1", width: 100)
        // 模拟 cachedWidth 已写入的场景(实际由 makeSize 或外部显式写)
        row.cachedWidth = 100
        let heightBefore = row.cachedHeight

        // 同宽度再调一次 —— 应该 early-return,高度不变,layout 不被重算
        MockComponent.layoutCallCount = 0
        row.makeSize(width: 100)
        XCTAssertEqual(MockComponent.layoutCallCount, 0,
            "width 没变 → `C.layout(...)` 不该被再调")
        XCTAssertEqual(row.cachedHeight, heightBefore)
    }

    func testComponentRowMakeSizeReLayoutsOnWidthChange() {
        let row = makeMockRow(text: "hello", stable: "s1", width: 100)
        row.cachedWidth = 100

        MockComponent.layoutCallCount = 0
        row.makeSize(width: 200)
        XCTAssertEqual(MockComponent.layoutCallCount, 1,
            "width 变 → `C.layout(...)` 必须重跑一次")
        XCTAssertEqual(row.cachedWidth, 200)
    }

    // MARK: - StatefulComponent fast path

    func testStatefulApplyStateUsesFastPath() {
        let input = StatefulMock.Input(text: "hello")
        let content = StatefulMock.prepare(input, theme: theme)
        let layout = StatefulMock.layout(content, theme: theme, width: 200, state: false)
        let row = ComponentRow<StatefulMock>(
            input: input, content: content, layout: layout,
            theme: theme, stableId: "s1")
        row.cachedWidth = 200

        StatefulMock.fullLayoutCallCount = 0
        StatefulMock.relayoutCallCount = 0

        // State toggle —— 必须走 relayouted,不碰 full layout
        row.apply(state: true)

        XCTAssertEqual(StatefulMock.fullLayoutCallCount, 0,
            "apply(state:) 不应触发 full layout(CT 重跑)")
        XCTAssertEqual(StatefulMock.relayoutCallCount, 1,
            "apply(state:) 应恰好调一次 relayouted")
        XCTAssertEqual(row.cachedWidth, 200, "fast path 不改 cachedWidth")
        XCTAssertEqual(row.cachedHeight,
            StatefulMock.expandedHeight(text: "hello"),
            "几何随 state 切换更新")
    }

    func testStatefulMakeSizeWidthChangeRunsFullLayout() {
        let input = StatefulMock.Input(text: "hello")
        let content = StatefulMock.prepare(input, theme: theme)
        let layout = StatefulMock.layout(content, theme: theme, width: 200, state: false)
        let row = ComponentRow<StatefulMock>(
            input: input, content: content, layout: layout,
            theme: theme, stableId: "s1")
        row.cachedWidth = 200

        StatefulMock.fullLayoutCallCount = 0
        StatefulMock.relayoutCallCount = 0

        // width 变 —— 必须走 full layout(CT 重跑),不走 relayouted
        row.makeSize(width: 400)

        XCTAssertEqual(StatefulMock.fullLayoutCallCount, 1,
            "width 变应触发 full layout")
        XCTAssertEqual(StatefulMock.relayoutCallCount, 0,
            "width 变不走快路径(旧 intermediate 已失效)")
        XCTAssertEqual(row.cachedWidth, 400)
    }

    func testStatefulApplyStateIsNoOpBeforeFirstLayout() {
        // Layout = nil(cache 里 stripped 版本,还没 makeSize 过)
        let input = StatefulMock.Input(text: "hello")
        let content = StatefulMock.prepare(input, theme: theme)
        let row = ComponentRow<StatefulMock>(
            input: input, content: content, layout: nil,
            theme: theme, stableId: "s1")

        StatefulMock.relayoutCallCount = 0
        row.apply(state: true)
        XCTAssertEqual(StatefulMock.relayoutCallCount, 0,
            "layout=nil 时 apply(state:) no-op,等 makeSize 首次跑完再调")
    }

    // MARK: - Sendable boundary smoke

    func testPrepareAndLayoutRunOffMainInDetachedTask() async throws {
        // Protocol 承诺 prepare / layout 是 nonisolated + 产物 Sendable,
        // 必须能在 detached task 里跑、把结果搬回 MainActor 用。
        let input = MockComponent.Input(text: "async-hello", seed: 7)
        let themeCopy = TranscriptTheme(markdown: .default)
        let (content, layout) = await Task.detached(priority: .userInitiated) {
            let content = MockComponent.prepare(input, theme: themeCopy)
            let layout = MockComponent.layout(content, theme: themeCopy, width: 300)
            return (content, layout)
        }.value

        XCTAssertEqual(content.text, "async-hello")
        XCTAssertEqual(layout.cachedHeight, MockComponent.mockHeight(text: "async-hello"))

        // 回主线程构造 row
        let row = MockComponent.makeRow(
            input: input, content: content, layout: layout,
            theme: themeCopy, stableId: "async-s1" as AnyHashable)
        XCTAssertEqual(row.stableId, AnyHashable("async-s1"))
        XCTAssertEqual(row.cachedHeight, layout.cachedHeight)
    }

    // MARK: - Helpers

    private func makeMockItem(
        text: String, stable: AnyHashable, width: CGFloat
    ) -> GenericPreparedItem<MockComponent> {
        let input = MockComponent.Input(text: text, seed: 1)
        let content = MockComponent.prepare(input, theme: theme)
        let layout = MockComponent.layout(content, theme: theme, width: width)
        let hash = MockComponent.contentHash(input, theme: theme)
        return GenericPreparedItem<MockComponent>(
            stable: stable, input: input, content: content,
            contentHashValue: hash, layout: layout)
    }

    private func makeMockRow(
        text: String, stable: AnyHashable, width: CGFloat
    ) -> ComponentRow<MockComponent> {
        let input = MockComponent.Input(text: text, seed: 1)
        let content = MockComponent.prepare(input, theme: theme)
        let layout = MockComponent.layout(content, theme: theme, width: width)
        return ComponentRow<MockComponent>(
            input: input, content: content, layout: layout,
            theme: theme, stableId: stable)
    }
}

// MARK: - MockComponent

/// 最小化测试 component:只证明协议/泛型骨架能跑通。不参与 builder 注册,
/// 不出现在生产 entries pipeline 里。
enum MockComponent: TranscriptComponent {
    static let tag = "MockComponent"

    struct Input: Sendable {
        let text: String
        let seed: Int
    }

    struct Content: Sendable {
        let text: String
    }

    struct Layout: HasHeight {
        let cachedHeight: CGFloat
    }

    /// 诊断计数器 —— 测试里用来断言 layout 路径有没有被调。
    /// Test-only,线程不安全(测试在 MainActor 单线程跑)。
    nonisolated(unsafe) static var layoutCallCount = 0

    /// 确定性的高度计算 —— tests 断言用。
    nonisolated static func mockHeight(text: String) -> CGFloat {
        CGFloat(text.count) * 10 + 4
    }

    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int
    ) -> [IdentifiedInput<Input>] {
        // Mock 不参与 entries pipeline
        []
    }

    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content {
        Content(text: input.text)
    }

    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.text)
        h.combine(input.seed)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat
    ) -> Layout {
        layoutCallCount += 1
        return Layout(cachedHeight: mockHeight(text: content.text))
    }

    @MainActor
    static func makeRow(
        input: Input,
        content: Content,
        layout: Layout?,
        theme: TranscriptTheme,
        stableId: AnyHashable
    ) -> TranscriptRow {
        ComponentRow<MockComponent>(
            input: input, content: content, layout: layout,
            theme: theme, stableId: stableId)
    }
}

// MARK: - StatefulMock

/// Stateful mock: 模拟 UserBubble 式的 "CT 贵 / 几何便宜" 两阶段,验证
/// `apply(state:)` 快路径只跑几何、`makeSize(width:)` 重跑 CT。
///
/// - `Layout.ctCost` 计数器: full layout 时 +1,relayouted 时不加,用来
///   区分两条路径。
enum StatefulMock: TranscriptComponent, StatefulComponent {
    static let tag = "StatefulMock"

    struct Input: Sendable {
        let text: String
    }

    struct Content: Sendable {
        let text: String
    }

    struct Layout: HasHeight, Sendable {
        let text: String
        let cachedHeight: CGFloat
        /// 模拟 "CT 产物,state 无关" —— relayouted 时原封不动传递。
        let intermediateSignature: Int
    }

    nonisolated(unsafe) static var fullLayoutCallCount = 0
    nonisolated(unsafe) static var relayoutCallCount = 0

    nonisolated static func collapsedHeight(text: String) -> CGFloat {
        CGFloat(text.count) * 10 + 4
    }
    nonisolated static func expandedHeight(text: String) -> CGFloat {
        CGFloat(text.count) * 10 + 20
    }

    nonisolated static func inputs(
        from entry: MessageEntry, entryIndex: Int
    ) -> [IdentifiedInput<Input>] { [] }

    nonisolated static func prepare(
        _ input: Input, theme: TranscriptTheme
    ) -> Content {
        Content(text: input.text)
    }

    nonisolated static func contentHash(
        _ input: Input, theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.text)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: TranscriptComponent (3 参 bridge)

    nonisolated static func layout(
        _ content: Content, theme: TranscriptTheme, width: CGFloat
    ) -> Layout {
        layout(content, theme: theme, width: width, state: false)
    }

    // MARK: StatefulComponent

    nonisolated static func initialState(for input: Input) -> Bool { false }

    nonisolated static func layout(
        _ content: Content, theme: TranscriptTheme, width: CGFloat, state expanded: Bool
    ) -> Layout {
        fullLayoutCallCount += 1
        // 模拟 "CT intermediate": 用 (text, width) hash 作为签名
        var h = Hasher()
        h.combine(content.text)
        h.combine(width)
        return Layout(
            text: content.text,
            cachedHeight: expanded ? expandedHeight(text: content.text)
                                   : collapsedHeight(text: content.text),
            intermediateSignature: h.finalize())
    }

    nonisolated static func relayouted(
        _ layout: Layout, theme: TranscriptTheme, state expanded: Bool
    ) -> Layout {
        relayoutCallCount += 1
        // 关键:复用 intermediate,只改 height
        return Layout(
            text: layout.text,
            cachedHeight: expanded ? expandedHeight(text: layout.text)
                                   : collapsedHeight(text: layout.text),
            intermediateSignature: layout.intermediateSignature)
    }

    @MainActor
    static func makeRow(
        input: Input, content: Content, layout: Layout?,
        theme: TranscriptTheme, stableId: AnyHashable
    ) -> TranscriptRow {
        ComponentRow<StatefulMock>(
            input: input, content: content, layout: layout,
            theme: theme, stableId: stableId)
    }
}
