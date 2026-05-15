import SwiftUI

/// v2 根视图：Sidebar v2 + 只读 ChatHistoryView。
/// 选中态本地持有，不走 AppState / ChatRouter。
struct RootView2: View {
    static fileprivate let detailCoordSpace = "RootView2.detail"

    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var barRect: CGRect = .zero

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView2(selection: $selectedSessionId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            if selectedSessionId == SidebarView2.transcriptDemoTag {
                TranscriptDemoView()
                    .frame(minWidth: 400)
            } else if selectedSessionId == SidebarView2.transcriptStressTag {
                TranscriptStressView()
                    .frame(minWidth: 400)
            } else if let sid = selectedSessionId {
                // `.id(sid)` 必须在**调用点**: 让 ChatHistoryView 整个 struct
                // 随 sessionId 重建,`@State handle` 跟着 reset。放在 body 内
                // 的 Group 上无效(只换 Group 子树,@State 保留跨 session)。
                ChatHistoryView(sessionId: sid)
                    .id(sid)
                    .frame(minWidth: 400)
                    .overlay(alignment: .bottom) {
                        // Fade scrim:detail pane 底部一道独立渐变,z-order 在
                        // transcript 之上、input bar 之下。bar 区域用 mask 抠
                        // 掉,这样 bar 的 glass / material 折射的就是 transcript
                        // 本身,不会叠一层灰。
                        LinearGradient(
                            colors: [
                                Color(nsColor: .windowBackgroundColor).opacity(0),
                                Color(nsColor: .windowBackgroundColor)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 160)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .mask {
                            Color.white
                                .overlay {
                                    if barRect != .zero {
                                        RoundedRectangle(cornerRadius: InputBarView2.cornerRadius)
                                            .fill(.black)
                                            .frame(width: barRect.width, height: barRect.height)
                                            .position(x: barRect.midX, y: barRect.midY)
                                            .blendMode(.destinationOut)
                                    }
                                }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        // 宽度对齐 NativeTranscript2 的 content band:min 一致,
                        // max = 0.8 * BlockStyle.maxLayoutWidth(780)= 624(4 倍数)。
                        // `onGeometryChange` 把 bar 在 detail coord space 里的
                        // frame 直接写入 @State,scrim 据此抠洞。bar 加在 padding
                        // 之内(`.frame` 之外),所以上报的 rect 就是 bar 本体
                        // (含 frame 约束,不含 padding 的 spacing 区)。
                        InputBarView2()
                            .frame(
                                minWidth: BlockStyle.minLayoutWidth,
                                maxWidth: 624
                            )
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.detailCoordSpace))
                            } action: { rect in
                                barRect = rect
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 36)
                    }
                    .coordinateSpace(name: Self.detailCoordSpace)
            } else {
                Color.clear
                    .frame(minWidth: 400)
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }
}

