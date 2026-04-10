import SwiftUI

/// SwiftUI 内容区容器。根据 activeAction 切换 Chat / Todo / Archive / NewProject。
struct ContentView: View {
    let activeAction: SidebarActionKind?
    @Bindable var chatRouter: ChatRouter
    let sidebarViewModel: SidebarViewModel
    let sessionService: SessionService
    let todoService: TodoService
    let todoSessionCoordinator: TodoSessionCoordinator
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
            if isChatVisible && chatRouter.currentSession.handle != nil {
                if chatRouter.currentSession.isViewingPlan {
                    PlanToolbarContent(session: chatRouter.currentSession)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Spacer()
                    }
                }
            }
        }
        .frame(minWidth: 400)
        .toolbar(showToolbar ? .automatic : .hidden, for: .windowToolbar)
        .searchable(text: $searchText, placement: .toolbar)
        .modifier(SearchFocusedModifier(isSearchFocused: $isSearchFocused))
        .onChange(of: searchText) { _, newValue in
            let session = chatRouter.currentSession
            if session.isViewingPlan {
                session.planSearchQuery = newValue
                chatRouter.planWebViewLoader.search(query: newValue, direction: "reset")
            } else {
                appState.searchQuery = newValue
                appState.searchTextChanged(newValue)
            }
        }
        .onSubmit(of: .search) {
            let session = chatRouter.currentSession
            if session.isViewingPlan {
                chatRouter.planWebViewLoader.search(
                    query: session.planSearchQuery, direction: "next"
                )
            } else {
                appState.findNext()
            }
        }
        .onChange(of: chatRouter.currentSession.isViewingPlan) { _, _ in
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
        case .todo:
            TodoView(
                todoService: todoService,
                todoSessionCoordinator: todoSessionCoordinator,
                sessionService: sessionService,
                onJumpToSession: onJumpToSession
            )
        case .archive:
            ArchiveView(sessionService: sessionService, sidebarViewModel: sidebarViewModel)
        case .newProject:
            NewProjectViewWrapper(chatRouter: chatRouter)
        #if DEBUG
        case .cardGallery:
            PermissionCardGalleryView()
        case .chatGallery:
            ChatGalleryView()
        case .planGallery:
            EmptyView() // handled by AppState.activatePlanGallery()
        #endif
        case .newConversation, nil:
            EmptyView()
        }
    }

    private var isChatVisible: Bool {
        activeAction == nil
    }

    private var showToolbar: Bool {
        !(isChatVisible && chatRouter.currentSession.handle == nil)
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
