import AgentSDK
import AppKit
import CoreText

// MARK: - GroupChildRenderer protocol
//
// 每个 GroupChild 的 parse / layout / draw 实现 —— 整 group 才是一个 NSTableView
// row,child 只是 GroupComponent.Content / Layout / render 内部的子元素,**不**
// 实现 `TranscriptComponent`。
//
// 加新富化 tool = 新建一个 struct conform to GroupChildRenderer + 在
// `GroupChildContent` / `GroupChildFrame` 加 case + 在 `dispatch(_:)` 加 switch
// 分支。没有 SideCar、cache key、stableId 这些 row-level concerns。

protocol GroupChildRenderer {
    associatedtype Content: Sendable
    associatedtype Frame: Sendable

    static func parse(_ tool: ToolUse, theme: TranscriptTheme) -> Content
    static func contentHash(_ tool: ToolUse, theme: TranscriptTheme) -> Int

    /// `(x, y)` row-local 起点;width 是内容列宽度。
    static func layout(
        _ content: Content,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        theme: TranscriptTheme
    ) -> Frame

    static func height(_ frame: Frame) -> CGFloat

    @MainActor
    static func draw(
        _ content: Content,
        frame: Frame,
        theme: TranscriptTheme,
        in ctx: CGContext
    )
}

// MARK: - Discriminated union (dispatch storage)
//
// `GroupComponent.Content.children` 直接持 `[GroupChildContent]`,layout 阶段产出
// `[GroupChildFrame]`。union 的 case 即等价于 dispatch 表 —— 加新 renderer 时
// 在这两个 enum 各加一 case + 在下方 `dispatch` switch 加分支。

enum GroupChildContent: @unchecked Sendable {
    case read(ReadChildRenderer.Content)
    case placeholder(PlaceholderChildRenderer.Content)
}

enum GroupChildFrame: Sendable {
    case read(ReadChildRenderer.Frame)
    case placeholder(PlaceholderChildRenderer.Frame)
}

// MARK: - Dispatch helpers

enum GroupChildDispatch {

    /// 按 ToolUse 类型选择 renderer 并 parse 出 Content。
    nonisolated static func parse(_ tool: ToolUse, theme: TranscriptTheme) -> GroupChildContent {
        switch tool {
        case .Read:
            return .read(ReadChildRenderer.parse(tool, theme: theme))
        default:
            return .placeholder(PlaceholderChildRenderer.parse(tool, theme: theme))
        }
    }

    nonisolated static func contentHash(_ tool: ToolUse, theme: TranscriptTheme) -> Int {
        switch tool {
        case .Read:
            return ReadChildRenderer.contentHash(tool, theme: theme)
        default:
            return PlaceholderChildRenderer.contentHash(tool, theme: theme)
        }
    }

    nonisolated static func layout(
        _ content: GroupChildContent,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        theme: TranscriptTheme
    ) -> GroupChildFrame {
        switch content {
        case .read(let c):
            return .read(ReadChildRenderer.layout(c, x: x, y: y, width: width, theme: theme))
        case .placeholder(let c):
            return .placeholder(PlaceholderChildRenderer.layout(c, x: x, y: y, width: width, theme: theme))
        }
    }

    nonisolated static func height(_ frame: GroupChildFrame) -> CGFloat {
        switch frame {
        case .read(let f):        return ReadChildRenderer.height(f)
        case .placeholder(let f): return PlaceholderChildRenderer.height(f)
        }
    }

    @MainActor
    static func draw(
        _ content: GroupChildContent,
        frame: GroupChildFrame,
        theme: TranscriptTheme,
        in ctx: CGContext
    ) {
        switch (content, frame) {
        case (.read(let c), .read(let f)):
            ReadChildRenderer.draw(c, frame: f, theme: theme, in: ctx)
        case (.placeholder(let c), .placeholder(let f)):
            PlaceholderChildRenderer.draw(c, frame: f, theme: theme, in: ctx)
        default:
            // Content / Frame 必须同 case —— layout 由 parse 结果驱动,不可能错配。
            assertionFailure("GroupChildDispatch.draw: content/frame kind mismatch")
        }
    }
}
