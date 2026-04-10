import SwiftUI
import Observation

/// 文本输入/补全/draft 管理。
@Observable
@MainActor
final class InputViewModel {

    // MARK: - Text State

    var text: String = "" {
        didSet { scheduleDraftSave() }
    }
    var cursorLocation: Int = 0
    /// Set after programmatic text replacement to reposition the cursor.
    var desiredCursorPosition: Int?
    var isFocused: Bool = false

    // MARK: - Computed

    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Completion

    let completionVM = CompletionViewModel()

    // MARK: - Slash Command Provider

    /// Slash command 提供者。computed，从 handle.slashCommands 构建。
    var slashCommandProvider: ((_ query: String, _ completion: @escaping ([SlashCommandStore.Match]) -> Void) -> Void)? {
        guard let handle, !handle.slashCommands.isEmpty else { return nil }
        let commands = handle.slashCommands
        return { query, cb in
            let matches = commands.map {
                SlashCommandStore.Match(name: $0.name, description: $0.description, rank: 0, isBuiltIn: $0.isBuiltIn)
            }.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }
            cb(matches)
        }
    }

    // MARK: - Dependencies

    private let sessionId: String
    weak var handle: SessionHandle?

    // MARK: - Init

    init(sessionId: String, handle: SessionHandle?) {
        self.sessionId = sessionId
        self.handle = handle
    }

    // MARK: - Draft Persistence

    static let newSessionDraftKey = "chatInputBarDraft_new"

    private var draftKey: String {
        handle == nil ? Self.newSessionDraftKey : "chatInputBarDraft_\(sessionId)"
    }

    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let key = draftKey
        let text = text
        draftSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if text.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(text, forKey: key)
            }
        }
    }

    func loadDraft() {
        text = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    /// 立即删除 UserDefaults 中的 draft 缓存，不清空 UI 输入框。
    func deleteDraft() {
        draftSaveTask?.cancel()
        UserDefaults.standard.removeObject(forKey: draftKey)
        UserDefaults.standard.removeObject(forKey: Self.newSessionDraftKey)
    }

    // MARK: - Text Operations

    /// 清空输入框并删除 draft。
    func clearInput() {
        deleteDraft()
        text = ""
    }

    func focusTextView() {
        isFocused = true
    }

    // MARK: - Completion Operations

    func checkCompletion(text: String, cursor: Int, hasMarkedText: Bool, context: CompletionTriggerContext) {
        completionVM.checkTrigger(text: text, cursorLocation: cursor, hasMarkedText: hasMarkedText, context: context)
    }

    func applyCompletionResult(keepSession: Bool) {
        guard var result = completionVM.confirmSelection(keepSession: keepSession) else { return }

        if keepSession, result.replacement.hasSuffix(" ") {
            result.replacement = String(result.replacement.dropLast())
        }

        let nsText = text as NSString
        if result.range.location + result.range.length <= nsText.length {
            let newCursor = result.range.location + result.replacement.count
            text = nsText.replacingCharacters(in: result.range, with: result.replacement)
            cursorLocation = newCursor
            desiredCursorPosition = newCursor
        }
    }

    func tryConfirmCompletionFromInput() -> Bool {
        guard let range = completionVM.tryConfirmFromInput() else { return false }

        let nsText = text as NSString
        if range.location + range.length <= nsText.length {
            text = nsText.replacingCharacters(in: range, with: "")
            cursorLocation = range.location
            desiredCursorPosition = range.location
        }
        return true
    }

    // MARK: - Send Preparation

    /// Guard canSend + deleteDraft + return trimmed text.
    func prepareSend() -> String? {
        guard canSend else { return nil }
        let result = trimmedText
        deleteDraft()
        return result
    }

    /// Enqueue message and clear input.
    func queueSend(handle: SessionHandle?) {
        let trimmed = trimmedText
        guard !trimmed.isEmpty else { return }
        handle?.enqueue(trimmed)
        clearInput()
    }

    // MARK: - Key Handling

    /// 补全相关快捷键处理。返回 true 表示事件已消费。
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard completionVM.isActive else { return false }

        let keyCode = event.keyCode
        // Up arrow
        if keyCode == 126 { completionVM.moveSelectionUp(); return true }
        // Down arrow
        if keyCode == 125 { completionVM.moveSelectionDown(); return true }
        // Return / Enter
        if keyCode == 36 || keyCode == 76 {
            applyCompletionResult(keepSession: false)
            return true
        }
        // Space — try input validation if session supports it (e.g. directory pick)
        if keyCode == 49, completionVM.hasInputValidation {
            if tryConfirmCompletionFromInput() { return true }
            return false  // let space insert normally; updateQuery will suspend
        }
        // Right arrow — drill down, keep session open for deeper navigation
        // With modifier keys (⌘/⌃/⌥), fall through to normal text editing
        if keyCode == 124, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            applyCompletionResult(keepSession: true)
            return true
        }
        // Tab — confirm, same as Enter
        if keyCode == 48 {
            applyCompletionResult(keepSession: false)
            return true
        }

        return false
    }
}
