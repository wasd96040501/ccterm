import AgentSDK
import AppKit
import SwiftUI

/// Native, NSTableView-backed chat transcript。对齐 Telegram macOS 的滚动性能：
/// - layer-backed 全栈 + `.never` redraw → live scroll 0 个 draw 调用
/// - 自绘 Core Text → 每行只做一次排版，CTLine 缓存
/// - NSTableView 的 rowView recycling 复用已经画好的 layer backing
///
/// 入口是 `NSViewRepresentable`，SwiftUI 侧可无感替换旧 `ChatTranscriptView`。
struct NativeTranscriptView: NSViewRepresentable {
    let entries: [MessageEntry]
    @Environment(\.markdownTheme) private var theme
    @Environment(\.syntaxEngine) private var syntaxEngine

    func makeNSView(context: Context) -> TranscriptScrollView {
        let sv = TranscriptScrollView()
        sv.controller.theme = theme
        sv.controller.syntaxEngine = syntaxEngine
        // Defer the first `setEntries` to `updateNSView` so we can lay out
        // against the real tableView width (SwiftUI inserts the view into the
        // hierarchy before updateNSView runs).
        return sv
    }

    func updateNSView(_ nsView: TranscriptScrollView, context: Context) {
        let ctrl = nsView.controller
        let themeChanged = ctrl.theme?.fingerprint != theme.fingerprint
        ctrl.theme = theme
        ctrl.syntaxEngine = syntaxEngine
        ctrl.setEntries(entries, themeChanged: themeChanged)
    }
}
