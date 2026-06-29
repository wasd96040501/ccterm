import AppKit
import Observation

/// AppKit replacement for the SwiftUI `NewSessionConfigurator<InputBar>` (the
/// compose card) — migration plan §4.6. A wide two-column card:
///
/// - **Left column** — `RecentProjectsStore`-backed recents list (`NSTableView`,
///   source-list style) with a "Projects" eyebrow header + a `+` button
///   (`NSOpenPanel`). Selecting a row writes the draft folder. Slate-blue recess
///   tint + 0.5pt trailing hairline.
/// - **Right column** — hero ("Start Building <name>") + abbreviated path
///   subtitle + worktree/branch meta pills + divider + a "Recent Sessions" list
///   for the picked folder + the embedded input bar z-overlaid at the bottom.
///
/// Folder / branch / worktree state lives on the resolved draft `Session`
/// (`session.draft.config`) — the single source of truth (`ComposeSessionView`'s
/// bindings become direct imperative setters here). `GitProbe` is driven
/// imperatively on every folder change (the `.task(id: folderPath)` analogue).
///
/// The card owns the embedded bar's POSITION only (a bottom-anchored z-overlay,
/// `.horizontal 28 .bottom 18`); the bar's per-session wiring lives on the passed
/// `InputBarController` (created + rebound by `ComposeSessionViewController`).
@MainActor
final class NewSessionConfiguratorViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    nonisolated deinit {}

    // MARK: - Constants (verbatim from NewSessionConfigurator.swift)

    /// Shared with the AppKit pill so card + bar read as one chrome family
    /// (`NewSessionConfigurator.swift:83` → `InputBarView.cornerRadius` = 16).
    static let cardCornerRadius: CGFloat = InputBarView.cornerRadius
    static let minWidth: CGFloat = 640
    static let idealWidth: CGFloat = 960
    static let maxWidth: CGFloat = 960
    static let height: CGFloat = 620
    static let minHeight: CGFloat = 360
    static let projectsColumnWidth: CGFloat = 280
    static let plusButtonSize: CGFloat = 22
    static let recentsBottomScrimHeight: CGFloat = 24
    /// Right-column bottom band reserved so recents stop above the bar
    /// (`NewSessionConfigurator.swift:369`).
    static let inputBarReservedHeight: CGFloat = 96
    static let resumeRowLimit: Int = 5
    static let resumeRowHPad: CGFloat = 8

    // MARK: - Injected dependencies

    let sessionManager: SessionManager
    let recents: RecentProjectsStore
    /// The embedded bar (created once + rebound by `ComposeSessionViewController`).
    /// The card owns its POSITION only.
    let inputBarController: InputBarController
    /// Row click in "Recent Sessions" → flip selection to `.session(id)`.
    let onResumeSession: (String) -> Void

    // MARK: - Bound draft session

    /// The draft session id this card configures. Bound ONCE (a stored `let`),
    /// never read reactively from `model.draftSessionId` (plan §4.6-7, R16).
    let draftSessionId: String
    /// Resolved draft `Session`; folder/branch/worktree read+write goes here.
    let session: Session

    /// Git info for the picked folder. Plain stored property driven imperatively
    /// (the `@State GitProbe` analogue). Seeded so the branch pill renders frame 1.
    let probe: GitProbe
    /// The heavy-probe Task; cancel-before-restart on every folder change.
    var heavyProbeTask: Task<Void, Never>?

    // MARK: - Reactive list refresh (self-re-arming observation)

    var recentsObservationActive = false
    var recordsObservationActive = false

    // MARK: - Left column views

    let recentsTableView = NSTableView()
    let recentsScrollView = NSScrollView()
    let emptyRecentsContainer = NSView()
    let recentsBottomScrim = TranscriptScrimView(
        edge: .bottom, bandHeight: NewSessionConfiguratorViewController.recentsBottomScrimHeight)
    var recentEntries: [RecentProjectsStore.Entry] = []

    // MARK: - Right column views

    let titleStaticLabel = NSTextField(labelWithString: String(localized: "Start Building"))
    let titleProjectLabel = NSTextField(labelWithString: "")
    let titleIcon = NSImageView()
    let subtitleLabel = NSTextField(labelWithString: "")
    let worktreeButton = CapsulePillButton()
    let branchButton = CapsulePillButton()
    let metaRow = NSStackView()
    /// Divider-top constraints, toggled in `refreshMetaRow`. When the meta row is
    /// hidden (non-git folder), the divider attaches directly under the subtitle
    /// so the row's slot collapses — matching the SwiftUI `if branchVisible {
    /// metaRow }` which removed the row from layout entirely
    /// (`NewSessionConfigurator.swift:390-398`). A hidden plain NSView still
    /// occupies its laid-out frame, so a static `divider.top == metaRow.bottom`
    /// would leave a ~24pt dead gap.
    var dividerTopFromMeta: NSLayoutConstraint?
    var dividerTopFromSubtitle: NSLayoutConstraint?
    let recentSessionsTableView = NSTableView()
    let recentSessionsScrollView = NSScrollView()
    let recentSessionsEmptyLabel = NSTextField(labelWithString: "")
    var recentSessionRecords: [SessionRecord] = []

    var branchPopover: NSPopover?
    /// The firstResponder captured before the branch popover stole key-window,
    /// restored on `popoverDidClose` (plan §4.2-1 / §4.6-8, R13). Weak so a
    /// racing teardown of the saved responder doesn't keep it alive.
    weak var savedBranchResponder: NSResponder?

    // MARK: - Init

    init(
        sessionManager: SessionManager,
        recents: RecentProjectsStore,
        inputBarController: InputBarController,
        draftSessionId: String,
        onResumeSession: @escaping (String) -> Void
    ) {
        self.sessionManager = sessionManager
        self.recents = recents
        self.inputBarController = inputBarController
        self.draftSessionId = draftSessionId
        self.session = sessionManager.prepareDraftSession(draftSessionId)
        self.probe = GitProbe(seedFolderPath: sessionManager.prepareDraftSession(draftSessionId).cwd)
        self.onResumeSession = onResumeSession
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Read accessors (derivations, verbatim from NewSessionConfigurator)

    /// Current folder path (`session.cwd`).
    var folderPath: String? { session.cwd }
    /// Display branch = `sourceBranch ?? probe.currentBranch ?? ""` (:534).
    var displayBranch: String { session.sourceBranch ?? probe.currentBranch ?? "" }
    /// Whether the branch pill renders (`probe.currentBranch != nil`, :379).
    var branchVisible: Bool { probe.currentBranch != nil }

    /// Trimmed last path component, or nil (`pickedFolderName`, :452-457).
    var pickedFolderName: String? {
        guard let folder = folderPath else { return nil }
        let name = (folder as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// `abbreviatedPath` (:476-483).
    func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// `recentSessionsForFolder` (:579-587): top-5 non-archived, non-draft
    /// records whose `groupingPath == folderPath`, desc by `lastActiveAt`.
    var recentSessionsForFolder: [SessionRecord] {
        guard let folder = folderPath else { return [] }
        return
            sessionManager.records
            .lazy
            .filter { $0.status != .archived && $0.status != .draft && $0.groupingPath == folder }
            .prefix(Self.resumeRowLimit)
            .map { $0 }
    }

    /// Compact relative-time string (`compactRelative`, :659-669) — reused
    /// verbatim, exposed for tests.
    static func compactRelative(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return ">7d"
    }
}
