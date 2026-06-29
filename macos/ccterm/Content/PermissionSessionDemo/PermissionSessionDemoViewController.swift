#if DEBUG

import AgentSDK
import AppKit
import SwiftUI

/// AppKit-rooted host for the end-to-end permission card layout demo.
/// Replaces the former SwiftUI `PermissionSessionDemoView` +
/// `ChatHistoryView` combo: the transcript is mounted directly via
/// `TranscriptScrollViewFactory`, the input bar is now a pure-AppKit
/// `InputBarController` hosted in a `RestingBarContainerView` (mirroring
/// production's `ChatSessionViewController.restingBarHost`), and the floating
/// permission-card controller stays SwiftUI but is hosted via `NSHostingView`.
/// The mocked `SessionManager` / `Session` pair, seed payload
/// (`TranscriptDemoViewController.initialBlocks`), and ControlPanel behavior
/// are carried over verbatim from the old view; only the mount strategy changed.
@MainActor
final class PermissionSessionDemoViewController: NSViewController {

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

    init(syntaxEngine: SyntaxHighlightEngine? = nil) {
        self.syntaxEngine = syntaxEngine
        self.seed = Seed.make()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private let syntaxEngine: SyntaxHighlightEngine?
    private let seed: Seed
    private var scroll: Transcript2ScrollView?
    private var sheetPresenter: Transcript2SheetPresenter?
    /// The pure-AppKit input bar (mirrors production's `inputBarController`),
    /// hosted in a `RestingBarContainerView` bottom-anchored to the pane.
    private var inputBarController: InputBarController?
    /// Full-pane permission-card host, mirroring production's
    /// `ChatSessionViewController.permissionCardHost`. Without it the
    /// `showCurrent()` control would set `pendingPermissions` but no card
    /// would ever render (PR5 moved the card out of `ChatRestingBar`).
    private var permissionCardHost: PermissionCardHostView?
    /// The AppKit card coordinator, mirroring production's
    /// `permissionCardController`. Bound to the seed session in `viewDidLoad`.
    private var permissionCardController: PermissionCardController?
    private var controlPanelHost: NSHostingView<ControlPanelHostView>?
    private let controlPanelState = ControlPanelState()
    /// Demo-local draft store so the hosted input bar resolves its draft
    /// (production supplies it from `AppState`). Temp-dir backed so the demo
    /// never touches the user's real input drafts.
    private let inputDraftStore = InputDraftStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-permission-demo-drafts", isDirectory: true))

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mountTranscript()
        installInputBar()
        installPermissionCardHost()
        installControlPanel()
        sheetPresenter = Transcript2SheetPresenter(controller: seed.controller, hostView: view)
        if let syntaxEngine {
            seed.controller.attachSyntaxEngine(syntaxEngine)
        }
        seed.seedHistoryIfNeeded()
        // Mirror ChatHistoryView's initial sync: keep the pill in line
        // with whatever isRunning currently reports (mocked CLI never
        // flips it, but the symmetry keeps demo behavior closer to
        // production).
        seed.controller.setLoading(seed.session.isRunning)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sheetPresenter?.stop()
        inputBarController?.prepareForRemoval()
        permissionCardController?.stop()
    }

    private func mountTranscript() {
        let controller = seed.controller
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        controller.scrollToTail()
        self.scroll = scroll
    }

    private func installInputBar() {
        // Mirror production: build the input bar ONCE as a child VC, host its
        // pill + chrome row in a `RestingBarContainerView` bottom-anchored at
        // its own intrinsic height, then `rebind` it to the seed session.
        let controller = InputBarController(
            sessionManager: seed.manager,
            inputDraftStore: inputDraftStore,
            onSubmit: { _, _ in })
        addChild(controller)
        inputBarController = controller
        // Force the child's `loadView` now so `barView` / `chromeRow` exist
        // before we build the host container (mirrors production's
        // `ChatSessionViewController.loadView`).
        controller.loadViewIfNeeded()

        let host = RestingBarContainerView(
            barView: controller.barView,
            chromeRow: controller.chromeRow,
            innerMaxWidth: ChatSessionViewController.composeMaxWidth,
            horizontalInset: ChatSessionViewController.detailHorizontalInset,
            bottomInset: ChatSessionViewController.chatBottomInset,
            barSpacing: RestingBarContainerView.barSpacing)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        let maxHostWidth = BlockStyle.maxLayoutWidth + 2 * ChatSessionViewController.detailHorizontalInset
        let widthFill = host.widthAnchor.constraint(equalToConstant: maxHostWidth)
        widthFill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth),
            host.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            widthFill,
        ])
        controller.rebind(sessionId: seed.sessionId)
    }

    /// Mirror production's `permissionCardHost`: a full-pane click-through
    /// `PermissionCardHostView` + `PermissionCardController`, layered above the
    /// bar host. PR5 moved the card out of `ChatRestingBar` into this overlay,
    /// so the demo must mount it too or `showCurrent()` would set
    /// `pendingPermissions` with nothing on screen.
    private func installPermissionCardHost() {
        let host = PermissionCardHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        permissionCardHost = host
        let controller = PermissionCardController(
            layerView: host,
            sessionManager: seed.manager,
            syntaxEngine: syntaxEngine)
        controller.rebind(for: seed.session)
        permissionCardController = controller
    }

    private func installControlPanel() {
        let panel = ControlPanelHostView(
            state: controlPanelState,
            isCurrentShown: { [seed, controlPanelState] in
                guard let pending = seed.session.pendingPermissions.first else { return false }
                return pending.id
                    == Self.kindFixtures[controlPanelState.selectedKindIndex].id
            },
            hasAny: { [seed] in !seed.session.pendingPermissions.isEmpty },
            onShow: { [weak self] in self?.showCurrent() },
            onHide: { [weak self] in self?.hideAll() },
            onMarkToolsRunning: { [weak self] in self?.markToolsRunning() },
            onEndTurn: { [weak self] in self?.endTurn() }
        )
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        controlPanelHost = host
    }

    // MARK: - Toggling pendingPermissions

    private func showCurrent() {
        guard let runtime = seed.session.runtime else { return }
        let item = Self.kindFixtures[controlPanelState.selectedKindIndex]
        let pending = PendingPermission(
            id: item.id,
            request: item.request,
            // Card button taps land here; mirror the production runtime
            // by popping the entry off the pending list. We don't care
            // about the decision payload — this is a layout demo.
            respond: { [weak runtime] _ in
                runtime?.pendingPermissions.removeAll { $0.id == item.id }
            }
        )
        runtime.pendingPermissions = [pending]
    }

    private func hideAll() {
        seed.session.runtime?.pendingPermissions.removeAll()
    }

    // MARK: - Tool-status testing

    /// Flip the seeded demo's running tool group + its bash child to
    /// `.running` via `setToolStatus`. Same id pair the transcript
    /// demo uses on cold-load, so the shimmer + progressive label
    /// appear on the row that `initialBlocks` already laid down.
    private func markToolsRunning() {
        let controller = seed.controller
        controller.setToolStatus(
            id: TranscriptDemoViewController.runningGroupBlockId, status: .running)
        controller.setToolStatus(
            id: TranscriptDemoViewController.runningBashChildId, status: .running)
    }

    /// Fire the same closure `SessionRuntime.finishTurn` fires on live
    /// `.result` — `Session.wireRuntimeMessagesSink` connects it to
    /// `bridge.handleTurnFinished()` →
    /// `controller.clearAllRunningStatuses()`. Exercises the full
    /// runtime → bridge → controller chain without needing a
    /// `Message2.result` fixture in app code.
    private func endTurn() {
        seed.session.runtime?.onTurnFinishedLive?()
    }

    // MARK: - Fixture pool

    fileprivate struct KindFixture: Identifiable {
        let id: String
        let label: String
        let request: PermissionRequest
    }

    fileprivate static let kindFixtures: [KindFixture] = [
        KindFixture(
            id: "demo-bash",
            label: "Bash · shell command",
            request: .makePreview(
                requestId: "demo-bash",
                toolName: "Bash",
                input: [
                    "command": "git push --force origin main",
                    "description": "Force-push the rebased branch",
                ])),
        KindFixture(
            id: "demo-edit",
            label: "Edit · file diff",
            request: .makePreview(
                requestId: "demo-edit",
                toolName: "Edit",
                input: [
                    "file_path": "/Users/example/Project/Sources/Greeter.swift",
                    "old_string": "print(\"hello\")",
                    "new_string": "print(\"hello, world\")",
                ])),
        KindFixture(
            id: "demo-edit-long",
            label: "Edit · long diff (tests 780pt cap)",
            request: .makePreview(
                requestId: "demo-edit-long",
                toolName: "Edit",
                input: [
                    "file_path": "/Users/example/Project/Sources/Localized.swift",
                    "old_string": (0..<25)
                        .map { "    case option\($0): return \"option-\($0)\"" }
                        .joined(separator: "\n"),
                    "new_string": (0..<25)
                        .map {
                            "    case option\($0): return String(localized: \"option-\($0)\")"
                        }
                        .joined(separator: "\n"),
                ])),
        KindFixture(
            id: "demo-webfetch",
            label: "WebFetch",
            request: .makePreview(
                requestId: "demo-webfetch",
                toolName: "WebFetch",
                input: [
                    "url": "https://docs.swift.org/swift-book/",
                    "prompt": "Summarise the section on protocols.",
                ])),
        KindFixture(
            id: "demo-enter-plan",
            label: "EnterPlanMode",
            request: .makePreview(
                requestId: "demo-enter-plan",
                toolName: "EnterPlanMode",
                input: [:])),
        KindFixture(
            id: "demo-ask",
            label: "AskUserQuestion",
            request: .makePreview(
                requestId: "demo-ask",
                toolName: "AskUserQuestion",
                input: [
                    "questions": [
                        [
                            "question":
                                "Should we keep backwards-compatibility shims for the old API?",
                            "header": "Compat",
                            "multiSelect": false,
                            "options": [
                                [
                                    "label": "Yes, keep them",
                                    "description": "Existing clients still depend on them",
                                ],
                                [
                                    "label": "No, remove them",
                                    "description": "Cleaner break, faster releases",
                                ],
                            ],
                        ]
                    ]
                ])),
    ]
}

// MARK: - Control panel

@Observable
@MainActor
fileprivate final class ControlPanelState {
    var selectedKindIndex: Int = 0
}

/// Floating control surface anchored to the bottom-trailing corner.
/// Bottom-centered would collide with the input bar / permission card
/// stack; the trailing corner keeps both visible at the same time.
fileprivate struct ControlPanelHostView: View {
    @Bindable var state: ControlPanelState
    let isCurrentShown: () -> Bool
    let hasAny: () -> Bool
    let onShow: () -> Void
    let onHide: () -> Void
    let onMarkToolsRunning: () -> Void
    let onEndTurn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permission Card Controller")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Picker("Kind", selection: $state.selectedKindIndex) {
                ForEach(
                    Array(PermissionSessionDemoViewController.kindFixtures.enumerated()),
                    id: \.offset
                ) { index, fx in
                    Text(fx.label).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 240)
            HStack(spacing: 8) {
                Button(action: onShow) {
                    Label("Show", systemImage: "eye")
                }
                .disabled(isCurrentShown())
                Button(action: onHide) {
                    Label("Hide", systemImage: "eye.slash")
                }
                .disabled(!hasAny())
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))

            Divider()

            Text("Tool Status")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                Button(action: onMarkToolsRunning) {
                    Label("Mark Running", systemImage: "wand.and.stars")
                }
                Button(action: onEndTurn) {
                    Label("End Turn", systemImage: "checkmark.circle")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
    }
}

// MARK: - Seed

/// One-shot fixture container. Built once at `init` of the VC and
/// persisted across its lifetime. Owns the in-memory repository, the
/// manager, and the cached `Session` the demo wires up.
@MainActor
fileprivate struct Seed {
    let sessionId: String
    let manager: SessionManager
    let session: Session
    let controller: Transcript2Controller
    /// Reference type wrapping a single Bool so a `struct` `Seed` can
    /// still flip "history seeded" idempotently from a `let` binding.
    private let seedToken = SeedToken()

    static func make() -> Seed {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let record = SessionRecord(
            sessionId: sid,
            title: "Permission Demo",
            cwd: "/tmp/demo",
            status: .created
        )
        repo.save(record)
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() }
        )
        // `session(_:)` materialises the cached `Session` (active
        // phase, since a record exists). Force-unwrap is safe — we
        // just wrote the record above.
        let session = manager.session(sid)!
        return Seed(
            sessionId: sid,
            manager: manager,
            session: session,
            controller: session.controller
        )
    }

    func seedHistoryIfNeeded() {
        guard !seedToken.done else { return }
        seedToken.done = true
        controller.apply(.append(TranscriptDemoViewController.initialBlocks))
        seedBackgroundTasks()
        seedTodos()
    }

    /// Push a representative mix of background bash tasks onto the
    /// runtime so the input-bar chrome's "task" button has something
    /// to show. The long-running entry intentionally carries an
    /// oversized command + output so the sheet exercises card
    /// expansion + the stream view's max-height scroll behavior.
    private func seedBackgroundTasks() {
        guard let runtime = session.runtime else { return }
        let oversizedCommand = """
            for i in $(seq 1 200); do
              echo "[ $(date +%H:%M:%S) ] tick $i — \
            running a deliberately long background bash command so the demo \
            can showcase how the BackgroundTaskCard handles wrapping, \
            stable expansion, and the inline output tail across multiple \
            paragraphs of monospaced content."
              sleep 1
            done
            """
        let running = BackgroundTask(
            id: "demo-bg-running",
            toolUseId: "toolu_demo_running",
            description: "Long-running tick generator (200 iterations)",
            taskType: "local_bash",
            command: oversizedCommand,
            outputFile: nil,
            startedAt: Date().addingTimeInterval(-92),
            endedAt: nil,
            status: .running,
            summary: nil
        )
        let completed = BackgroundTask(
            id: "demo-bg-completed",
            toolUseId: "toolu_demo_completed",
            description: "Background sleep + echo",
            taskType: "local_bash",
            command: "sleep 5 && echo finished",
            outputFile: "/private/tmp/demo/tasks/demo-bg-completed.output",
            startedAt: Date().addingTimeInterval(-340),
            endedAt: Date().addingTimeInterval(-330),
            status: .completed,
            summary: "Background command \"Background sleep + echo\" completed (exit code 0)"
        )
        let failed = BackgroundTask(
            id: "demo-bg-failed",
            toolUseId: "toolu_demo_failed",
            description: "Migration smoke (rolled back)",
            taskType: "local_bash",
            command: "make test-unit FILTER=MigrationSmoke",
            outputFile: "/private/tmp/demo/tasks/demo-bg-failed.output",
            startedAt: Date().addingTimeInterval(-720),
            endedAt: Date().addingTimeInterval(-680),
            status: .failed,
            summary: "Background command \"Migration smoke\" failed (exit code 1)"
        )
        runtime.taskTracker.tasks = [completed, failed, running]
    }

    /// Push a representative todo plan onto the runtime so the
    /// chrome's todo button + popover have something to render. The
    /// mix is one `inProgress` row at the top, one `pending` follower,
    /// and three `completed` rows underneath — enough to exercise the
    /// active / completed grouping and the dimmed-row styling.
    private func seedTodos() {
        guard let runtime = session.runtime else { return }
        let now = Date()
        runtime.todoTracker.todos = [
            TodoEntry(
                id: "1",
                subject: "Read the existing transcript renderer doc",
                description: "Skim NativeTranscript2/CLAUDE.md to understand the diff path before editing.",
                activeForm: nil,
                status: .completed,
                createdAt: now.addingTimeInterval(-720),
                updatedAt: now.addingTimeInterval(-650)
            ),
            TodoEntry(
                id: "2",
                subject: "Audit existing popover row spacing tokens",
                description: nil,
                activeForm: nil,
                status: .completed,
                createdAt: now.addingTimeInterval(-700),
                updatedAt: now.addingTimeInterval(-540)
            ),
            TodoEntry(
                id: "3",
                subject: "Sketch the memo-style todo popover",
                description: "Leading status circle, grouped Active / Done sections, completed rows dimmed.",
                activeForm: "Drafting the todo popover layout",
                status: .inProgress,
                createdAt: now.addingTimeInterval(-480),
                updatedAt: now.addingTimeInterval(-120)
            ),
            TodoEntry(
                id: "4",
                subject: "Wire the chrome button visibility rules",
                description: "Hidden when no todos; stays mounted once any row exists.",
                activeForm: nil,
                status: .pending,
                createdAt: now.addingTimeInterval(-360),
                updatedAt: now.addingTimeInterval(-360)
            ),
            TodoEntry(
                id: "5",
                subject: "Add a snapshot test for the popover",
                description: nil,
                activeForm: nil,
                status: .pending,
                createdAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-300)
            ),
            TodoEntry(
                id: "6",
                subject: "Localize all new strings (zh-Hans)",
                description: nil,
                activeForm: nil,
                status: .completed,
                createdAt: now.addingTimeInterval(-640),
                updatedAt: now.addingTimeInterval(-440)
            ),
        ]
    }
}

@MainActor
fileprivate final class SeedToken {
    var done: Bool = false
}

#endif
