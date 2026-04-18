import Foundation
import Observation
import AgentSDK

@Observable
@MainActor
class SessionHandle2 {

    enum Status {
        case notStarted
        case starting
        case idle
        case responding
        case interrupting
        case stopped(ProcessExit?)
    }

    enum HistoryLoadState {
        case notLoaded
        case loading
        case loaded
        case failed(String)
    }

    // MARK: - Identity

    let sessionId: String

    // MARK: - Status

    private(set) var status: Status = .notStarted
    private(set) var historyLoadState: HistoryLoadState = .notLoaded

    // MARK: - Configuration

    private(set) var cwd: String?
    private(set) var isWorktree: Bool = false
    private(set) var model: String?
    private(set) var effort: Effort?
    private(set) var permissionMode: PermissionMode = .default

    // MARK: - Runtime

    private(set) var messages: [MessageEntry] = []
    private(set) var pendingPermissions: [PendingPermission] = []
    private(set) var contextUsedTokens: Int = 0
    private(set) var contextWindowTokens: Int = 0
    private(set) var slashCommands: [SlashCommand] = []
    private(set) var availableModels: [String] = []

    // MARK: - Presence

    private(set) var isFocused: Bool = false
    private(set) var hasUnread: Bool = false

    // MARK: - Init

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    // MARK: - Lifecycle commands

    func start() { fatalError() }
    func stop() { fatalError() }

    // MARK: - Messaging commands

    func send(_ message: SessionMessage) { fatalError() }
    func interrupt() { fatalError() }
    func cancelMessage(id: UUID) { fatalError() }

    // MARK: - Configuration commands

    func setModel(_ model: String?) { fatalError() }
    func setEffort(_ effort: Effort?) { fatalError() }
    func setPermissionMode(_ mode: PermissionMode) { fatalError() }
    func setCwd(_ cwd: String) { fatalError() }
    func setWorktree(_ isWorktree: Bool) { fatalError() }

    // MARK: - Permission

    func respond(to permissionId: String, decision: PermissionDecision) { fatalError() }

    // MARK: - Presence

    func setFocused(_ focused: Bool) { fatalError() }
}
