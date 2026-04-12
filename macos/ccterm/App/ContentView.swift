import SwiftUI

/// SwiftUI 内容区容器。根据 activeAction 切换 Chat / Todo / Archive / NewProject。
struct ContentView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var handle: SessionHandle? { appVM.sessionService.activeHandle }

    var body: some View {
        ZStack {
            ChatView()
                .opacity(isChatVisible ? 1 : 0)
                .allowsHitTesting(isChatVisible)

            if !isChatVisible {
                nonChatContent
            }
        }
        .toolbar {
            if isChatVisible && handle?.status != .notStarted && handle != nil {
                if handle?.activePlanReviewId != nil {
                    PlanToolbarContent(handle: handle!)
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
            if let handle, handle.activePlanReviewId != nil {
                handle.planSearchQuery = newValue
                appVM.planRendererService.search(query: newValue, direction: "reset")
            } else {
                appVM.searchQuery = newValue
                appVM.searchTextChanged(newValue)
            }
        }
        .onSubmit(of: .search) {
            if let handle, handle.activePlanReviewId != nil {
                appVM.planRendererService.search(
                    query: handle.planSearchQuery, direction: "next"
                )
            } else {
                appVM.findNext()
            }
        }
        .onChange(of: handle?.activePlanReviewId) { _, _ in
            searchText = ""
        }
        .onChange(of: appVM.searchFocusTrigger) { _, newValue in
            if newValue {
                isSearchFocused = true
                appVM.searchFocusTrigger = false
            }
        }
    }

    @ViewBuilder
    private var nonChatContent: some View {
        switch appVM.activeAction {
        case .archive:
            ArchiveView(sessionService: appVM.sessionService, sidebarViewModel: appVM.sidebarViewModel)
        #if DEBUG
        case .cardGallery:
            PermissionCardGalleryView()
        case .chatGallery:
            ChatGalleryView()
        case .planGallery:
            EmptyView() // handled by AppViewModel.activatePlanGallery()
        case .scrollHugTest:
            ScrollHugTestView()
        #endif
        case .newConversation, nil:
            EmptyView()
        }
    }

    private var isChatVisible: Bool {
        appVM.activeAction == nil
    }

    private var showToolbar: Bool {
        !(isChatVisible && handle?.status == .notStarted)
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
