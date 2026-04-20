import SwiftUI

/// SwiftUI 内容区容器。根据 activeAction 切换 Chat / Todo / Archive / NewProject。
struct ContentView: View {
    let activeAction: SidebarActionKind?
    @Bindable var chatRouter: ChatRouter
    let sidebarViewModel: SidebarViewModel
    let sessionService: SessionService
    let onJumpToSession: (String) -> Void

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            ChatView(chatRouter: chatRouter)
                .opacity(isChatVisible ? 1 : 0)
                .allowsHitTesting(isChatVisible)

            if !isChatVisible {
                nonChatContent
            }
        }
        .toolbar {
            if isChatVisible && chatRouter.currentViewModel.handle != nil {
                if chatRouter.currentViewModel.planReviewVM.isActive {
                    PlanToolbarContent(viewModel: chatRouter.currentViewModel.planReviewVM)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Spacer()
                    }
                }
            }
        }
        .frame(minWidth: 400)
        .modifier(ConditionalSearchModifier(
            text: $searchText,
            isSearchFocused: $isSearchFocused,
            isEnabled: showToolbar
        ))
        .onChange(of: searchText) { _, newValue in
            let vm = chatRouter.currentViewModel
            if vm.planReviewVM.isActive {
                vm.planReviewVM.searchQuery = newValue
                chatRouter.planWebViewLoader.search(query: newValue, direction: "reset")
            } else {
                appState.searchQuery = newValue
                appState.searchTextChanged(newValue)
            }
        }
        .onSubmit(of: .search) {
            let vm = chatRouter.currentViewModel
            if vm.planReviewVM.isActive {
                chatRouter.planWebViewLoader.search(
                    query: vm.planReviewVM.searchQuery, direction: "next"
                )
            } else {
                appState.findNext()
            }
        }
        .onChange(of: chatRouter.currentViewModel.planReviewVM.isActive) { _, _ in
            searchText = ""
        }
        .onChange(of: appState.searchFocusTrigger) { _, newValue in
            if newValue {
                isSearchFocused = true
                appState.searchFocusTrigger = false
            }
        }
    }

    @ViewBuilder
    private var nonChatContent: some View {
        switch activeAction {
        case .archive:
            ArchiveView(sessionService: sessionService, sidebarViewModel: sidebarViewModel)
        case .newConversation, nil:
            EmptyView()
        }
    }

    private var isChatVisible: Bool {
        activeAction == nil
    }

    private var showToolbar: Bool {
        !(isChatVisible && chatRouter.currentViewModel.handle == nil)
    }
}

/// 条件性搜索修饰符：启用时显示搜索框，禁用时不添加 .searchable，
/// 避免 .toolbar(.hidden) 导致窗口控制按钮消失。
private struct ConditionalSearchModifier: ViewModifier {
    @Binding var text: String
    var isSearchFocused: FocusState<Bool>.Binding
    var isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, placement: .toolbar)
                .modifier(SearchFocusedModifier(isSearchFocused: isSearchFocused))
        } else {
            content
        }
    }
}

private struct SearchFocusedModifier: ViewModifier {
    var isSearchFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(isSearchFocused)
        } else {
            content
        }
    }
}
