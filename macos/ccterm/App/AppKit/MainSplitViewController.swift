import AppKit
import SwiftUI

/// Two-item `NSSplitViewController` that hosts the sidebar (SwiftUI
/// `SidebarView2` via `NSHostingController`) on the leading side and
/// the AppKit-rooted `TranscriptDetailViewController` on the trailing
/// side. Replaces `RootView2`'s `NavigationSplitView` wrapper.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let model: MainSelectionModel
    let appState: AppState
    let searchBus: TranscriptSearchBus

    let detailViewController: TranscriptDetailViewController
    private let sidebarHostingController: NSHostingController<AnyView>

    init(model: MainSelectionModel, appState: AppState, searchBus: TranscriptSearchBus) {
        self.model = model
        self.appState = appState
        self.searchBus = searchBus

        let bindable = SidebarSelectionBinding(model: model)
        let sidebar = SidebarView2(selection: bindable.selectionBinding)
            .environment(appState.sessionManager)
            .environment(appState.recentProjects)
            .environment(appState.inputDraftStore)
            .environment(\.syntaxEngine, appState.syntaxEngine)
            .environment(searchBus)
            .environment(appState.notificationService)
        sidebarHostingController = NSHostingController(rootView: AnyView(sidebar))

        detailViewController = TranscriptDetailViewController(
            model: model,
            sessionManager: appState.sessionManager,
            recentProjects: appState.recentProjects,
            notifications: appState.notificationService,
            searchEngine: appState.syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: appState.inputDraftStore
        )

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        super.loadView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 350
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .automatic
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 680
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
    }
}

/// `SidebarView2` takes a SwiftUI `@Binding<String?>`. The binding has
/// to capture the `MainSelectionModel` by reference. Wrapping the
/// closure pair in a small helper keeps that ownership explicit.
@MainActor
private final class SidebarSelectionBinding {
    let model: MainSelectionModel

    init(model: MainSelectionModel) {
        self.model = model
    }

    var selectionBinding: Binding<String?> {
        Binding(
            get: { self.model.selectedSessionId },
            set: { self.model.selectedSessionId = $0 }
        )
    }
}
