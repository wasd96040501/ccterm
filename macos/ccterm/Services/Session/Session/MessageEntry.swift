import AgentSDK
import Foundation

// MARK: - Entry

/// Timeline entry. Either a plain single message or a group of adjacent
/// same-class tool_use assistant messages.
///
/// Invariant: `.group` never nests — `GroupEntry.items` contains raw
/// `SingleEntry`s.
enum MessageEntry: Identifiable {
    case single(SingleEntry)
    case group(GroupEntry)

    var id: UUID {
        switch self {
        case .single(let e): return e.id
        case .group(let g): return g.id
        }
    }

    /// Convenience forwarder to the inner `.single` payload. Getter returns `nil`
    /// for `.group`; setter is a no-op on `.group`.
    var delivery: DeliveryState? {
        get {
            if case .single(let e) = self { return e.delivery }
            return nil
        }
        set {
            guard case .single(var e) = self else { return }
            e.delivery = newValue
            self = .single(e)
        }
    }
}

// MARK: - SingleEntry

struct SingleEntry: Identifiable {
    let id: UUID
    var payload: Payload
    var delivery: DeliveryState?
    /// Each of this entry's tool calls that has been answered, keyed by
    /// tool_use id: the user message carrying just that call's result (see
    /// `UserMessage.toolResultMessages`), so `toolOutcome(_:)` reads it.
    var toolResults: [String: UserMessage]

    /// Payload has two shapes:
    /// - `.localUser`: an entry just appended by `send(text:)` / `send(image:)`,
    ///   not yet echoed by the CLI. Retains raw text / image / planContent so
    ///   `writeUserEntryToCLI` can read them directly.
    /// - `.remote`: a message from the CLI (or history). When a user echo
    ///   arrives, `.localUser` is replaced by `.remote`; assistant entries
    ///   are always `.remote`.
    enum Payload {
        case localUser(LocalUserInput)
        case remote(Message)
    }
}

/// Snapshot of a user message we sent locally. Captured at the `send(_:)`
/// entry so `writeUserEntryToCLI` can read the fields directly.
///
/// `images` is plural to match the wire `content` array: a single message
/// can carry text + N image blocks, encoded back-to-back. Empty `images`
/// means a pure-text send; non-empty means at least one inline image.
struct LocalUserInput {
    var text: String?
    var images: [(data: Data, mediaType: String)]
    var planContent: String?

    init(text: String?, images: [(data: Data, mediaType: String)] = [], planContent: String? = nil) {
        self.text = text
        self.images = images
        self.planContent = planContent
    }
}

extension SingleEntry {
    /// Non-nil only for `.remote` payloads.
    var remoteMessage: Message? {
        if case .remote(let m) = payload { return m }
        return nil
    }

    /// All `toolUse` blocks inside an assistant single, in order. Empty for
    /// user / non-assistant / non-tool_use messages.
    var toolUses: [ToolUseBlock] {
        guard case .assistant(let a) = remoteMessage else { return [] }
        return a.content.compactMap { block in
            if case .toolUse(let t) = block { return t }
            return nil
        }
    }

    /// Whether this assistant single originated the given tool_use id.
    func ownsToolUse(_ id: String) -> Bool {
        toolUses.contains { $0.id == id }
    }
}

// MARK: - GroupEntry

struct GroupEntry: Identifiable {
    let id: UUID
    var items: [SingleEntry]
}

extension GroupEntry {
    /// Group title — three forms keyed on (isActive, isExpanded).
    ///
    /// - `(active, collapsed)` → ``activeTitle`` (progressive fragment of the
    ///   **last** tool, e.g. `Reading foo.swift`).
    /// - `(active, expanded)` → ``expandedActiveTitle`` (aggregated progressive,
    ///   e.g. `Reading 3 files · Searching 1 pattern`).
    /// - `(completed, *)` → ``completedTitle`` (aggregated past tense, e.g.
    ///   `Read 3 files · Searched 1 pattern`).
    func title(isActive: Bool, isExpanded: Bool = false) -> String {
        switch (isActive, isExpanded) {
        case (true, false): return activeTitle
        case (true, true): return expandedActiveTitle
        case (false, _): return completedTitle
        }
    }

    var activeTitle: String {
        guard let last = items.last,
            let tool = last.toolUses.first
        else { return "" }
        return tool.activeFragment ?? ""
    }

    /// Aggregated progressive form for the expanded-active state — same
    /// "first-occurrence order, count-suffixed" structure as ``completedTitle``,
    /// but each kind picks its present-continuous phrase.
    var expandedActiveTitle: String {
        aggregatedTitle { kind, count in kind.activeCountPhrase(count) }
    }

    var completedTitle: String {
        aggregatedTitle { kind, count in kind.completedCountPhrase(count) }
    }

    private func aggregatedTitle(
        _ phrase: (GroupableToolName, Int) -> String
    ) -> String {
        var order: [GroupableToolName] = []
        var counts: [GroupableToolName: Int] = [:]
        for item in items {
            for tool in item.toolUses {
                let kind = tool.groupableKind
                if counts[kind] == nil { order.append(kind) }
                counts[kind, default: 0] += 1
            }
        }
        return order.compactMap { kind in
            counts[kind].map { phrase(kind, $0) }
        }
        .joined(separator: " · ")
    }
}

// MARK: - DeliveryState

/// User entry lifecycle.
///
/// - `queued`: appended locally but no CLI echo yet (CLI might not be up,
///   still bootstrapping, or busy with a prior turn — the message may be
///   queued CLI-side).
/// - `confirmed`: CLI echoed back a user message with the same uuid — the
///   turn has actually begun processing.
/// - `failed`: process exit or other unrecoverable error; UI can surface this.
///
/// `delivery` is always nil for non-user entries.
enum DeliveryState: Equatable {
    case queued
    case confirmed
    case failed(reason: String)
}

// MARK: - GroupableToolName

/// All tool kinds are groupable — any contiguous run of pure-tool_use assistant
/// messages folds into one ``GroupEntry``. Kinds outside the rich-rendered
/// whitelist fall through to ``other``, which keeps grouping behavior but
/// shows a generic phrase (e.g. `Used 2 tools`).
enum GroupableToolName {
    case read
    case edit
    case write
    case grep
    case glob
    case bash
    case webFetch
    case webSearch
    case agent
    case askUserQuestion
    case other

    /// Past-tense aggregated phrase for the completed group title. Plural form
    /// selected via xcstrings `%lld` variation.
    func completedCountPhrase(_ count: Int) -> String {
        switch self {
        case .read: return String(localized: "Read \(count) files")
        case .edit: return String(localized: "Edited \(count) files")
        case .write: return String(localized: "Wrote \(count) files")
        case .grep: return String(localized: "Searched \(count) patterns")
        case .glob: return String(localized: "Globbed \(count) patterns")
        case .bash: return String(localized: "Ran \(count) commands")
        case .webFetch: return String(localized: "Fetched \(count) URLs")
        case .webSearch: return String(localized: "Searched \(count) queries")
        case .agent: return String(localized: "Ran \(count) agents")
        case .askUserQuestion: return String(localized: "Asked \(count) questions")
        case .other: return String(localized: "Used \(count) tools")
        }
    }

    /// Present-continuous aggregated phrase for the expanded-active group title.
    func activeCountPhrase(_ count: Int) -> String {
        switch self {
        case .read: return String(localized: "Reading \(count) files")
        case .edit: return String(localized: "Editing \(count) files")
        case .write: return String(localized: "Writing \(count) files")
        case .grep: return String(localized: "Searching \(count) patterns")
        case .glob: return String(localized: "Globbing \(count) patterns")
        case .bash: return String(localized: "Running \(count) commands")
        case .webFetch: return String(localized: "Fetching \(count) URLs")
        case .webSearch: return String(localized: "Searching \(count) queries")
        case .agent: return String(localized: "Running \(count) agents")
        case .askUserQuestion: return String(localized: "Asking \(count) questions")
        case .other: return String(localized: "Using \(count) tools")
        }
    }
}

// MARK: - ToolUse classification / fragments

extension ToolUseBlock {
    /// Always returns a grouping kind — every tool_use participates in grouping.
    /// Rich-rendered tools map to their dedicated case; everything else falls
    /// through to ``GroupableToolName/other``.
    var groupableKind: GroupableToolName {
        if Tools.Read.matches(name) { return .read }
        if Tools.Edit.matches(name) { return .edit }
        if Tools.Write.matches(name) { return .write }
        if Tools.Grep.matches(name) { return .grep }
        if Tools.Glob.matches(name) { return .glob }
        if Tools.Bash.matches(name) { return .bash }
        if Tools.WebFetch.matches(name) { return .webFetch }
        if Tools.WebSearch.matches(name) { return .webSearch }
        if Tools.Agent.matches(name) { return .agent }
        if Tools.AskUserQuestion.matches(name) { return .askUserQuestion }
        return .other
    }

    /// Progressive / present-continuous phrase (e.g. `Reading foo.swift`).
    /// Consumed by both group titles and standalone ToolBlock headers while
    /// the tool is running. `nil` for tools where the bare tool name reads
    /// better.
    var activeFragment: String? {
        switch groupableKind {
        case .read: return String(localized: "Reading \(fileTarget)")
        case .edit: return String(localized: "Editing \(fileTarget)")
        case .write: return String(localized: "Writing \(fileTarget)")
        case .grep: return String(localized: "Searching \"\(patternTarget)\"")
        case .glob: return String(localized: "Globbing \"\(patternTarget)\"")
        case .bash: return String(localized: "Running \(bashTarget)")
        case .webFetch: return String(localized: "Fetching \(webFetchTarget)")
        case .webSearch: return String(localized: "Searching \"\(webSearchTarget)\"")
        case .agent: return String(localized: "Running agent: \(agentTarget)")
        case .askUserQuestion: return String(localized: "Asking: \(askTarget)")
        case .other: return nil
        }
    }

    /// Past-tense counterpart of ``activeFragment`` (e.g. `Read foo.swift`).
    /// Used for standalone ToolBlock headers once the tool finishes. Group
    /// titles have their own aggregated form (`Read 3 files · …`) and do not
    /// go through this.
    var completedFragment: String? {
        switch groupableKind {
        case .read: return String(localized: "Read \(fileTarget)")
        case .edit: return String(localized: "Edited \(fileTarget)")
        case .write: return String(localized: "Wrote \(fileTarget)")
        case .grep: return String(localized: "Searched \"\(patternTarget)\"")
        case .glob: return String(localized: "Globbed \"\(patternTarget)\"")
        case .bash: return String(localized: "Ran \(bashTarget)")
        case .webFetch: return String(localized: "Fetched \(webFetchTarget)")
        case .webSearch: return String(localized: "Searched \"\(webSearchTarget)\"")
        case .agent: return String(localized: "Agent: \(agentTarget)")
        case .askUserQuestion: return String(localized: "Asked: \(askTarget)")
        case .other: return nil
        }
    }

    // MARK: Fragment targets

    /// Basename of the `file_path` a Read / Edit / Write call targets (read
    /// raw: the key is shared by the three tools).
    private var fileTarget: String {
        guard let path = input["file_path"]?.stringValue, !path.isEmpty else { return String(localized: "file") }
        return (path as NSString).lastPathComponent
    }

    /// Grep's and Glob's shared `pattern` key.
    private var patternTarget: String { input["pattern"]?.stringValue ?? "" }

    private var bashTarget: String {
        let bash = input(as: Tools.Bash.self)
        return bash?.description ?? bash.map { String($0.command.prefix(40)) } ?? ""
    }

    private var webFetchTarget: String { input(as: Tools.WebFetch.self)?.url ?? "" }

    private var webSearchTarget: String { input(as: Tools.WebSearch.self)?.query ?? "" }

    private var agentTarget: String { input(as: Tools.Agent.self)?.description ?? "" }

    private var askTarget: String { input(as: Tools.AskUserQuestion.self)?.questions.first?.question ?? "" }
}
