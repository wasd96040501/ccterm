import SwiftUI
import AgentSDK

/// 权限卡片容器 —— 直接吃 `[PendingPermission]`,无中间 ViewModel。
/// 每条 PendingPermission 映射到一张 card,多条时顶部展示分页指示。
///
/// Card view model 按 permission id 缓存,避免每次重渲染丢掉 AskUserQuestion 的
/// radio 选择 / ExitPlanMode 的 plan markdown 等子状态。
struct PermissionOverlayView: View {

    let pendingPermissions: [PendingPermission]

    @State private var currentIndex: Int = 0
    @State private var cardCache: [String: PermissionCardType] = [:]

    private var currentItem: (id: String, type: PermissionCardType)? {
        guard currentIndex < pendingPermissions.count else { return nil }
        let pending = pendingPermissions[currentIndex]
        let type = cardCache[pending.id] ?? makeCard(for: pending)
        return (pending.id, type)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if pendingPermissions.count > 1 {
                    PageDotIndicatorSwiftUIView(
                        count: pendingPermissions.count,
                        currentIndex: $currentIndex
                    )
                }
            }
            .frame(height: 16)
            .padding(.top, 2)

            if let item = currentItem {
                cardView(for: item.type)
                    .id(item.id)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: currentIndex)
        .onAppear { syncCache() }
        .onChange(of: pendingPermissions.map(\.id)) { _, _ in syncCache() }
    }

    @ViewBuilder
    private func cardView(for type: PermissionCardType) -> some View {
        switch type {
        case .standard(let vm): StandardCardView(viewModel: vm)
        case .exitPlanMode(let vm): ExitPlanModeCardView(viewModel: vm)
        case .askUserQuestion(let vm): SwiftUIAskUserQuestionCardView(viewModel: vm)
        }
    }

    /// 按 id 同步缓存:新增 id 创建 card vm,移除 id 清掉缓存。currentIndex
    /// 越界时回拢到合法范围,空列表保持 0(view 自然折叠)。
    private func syncCache() {
        let liveIds = Set(pendingPermissions.map(\.id))
        // 清掉已不在 pending 列表的 vm
        for key in cardCache.keys where !liveIds.contains(key) {
            cardCache.removeValue(forKey: key)
        }
        // 为新 id 创建 vm
        for pending in pendingPermissions where cardCache[pending.id] == nil {
            cardCache[pending.id] = makeCard(for: pending)
        }
        if currentIndex >= pendingPermissions.count {
            currentIndex = max(0, pendingPermissions.count - 1)
        }
    }

    private func makeCard(for pending: PendingPermission) -> PermissionCardType {
        PermissionCardViewModelFactory.make(
            for: pending.request,
            onDecision: { decision in pending.respond(decision) },
            onNewSession: nil
        )
    }
}
