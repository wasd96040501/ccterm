import Foundation
import Observation

// MARK: - CompletionViewModel

@Observable
final class CompletionViewModel {

    // MARK: - Public State

    enum EmptyReason {
        case loading
        case noMatches
        case noDirectory
    }

    var items: [any CompletionItem] = []
    var selectedIndex: Int = 0
    var isLoading: Bool = false
    var emptyReason: EmptyReason = .noMatches

    /// Cursor location in the text, written by the input view.
    var cursorLocation: Int = 0

    var hasSession: Bool { activeSession != nil }

    /// Completion list is visible when a session exists and cursor is within the trigger word.
    var isActive: Bool {
        guard let session = activeSession else { return false }
        if session.emptyReasonOverride == .noDirectory { return true }
        let range = wordRange(for: session)
        return cursorLocation > session.anchorLocation && cursorLocation <= range.upperBound
    }

    var headerText: String? { activeSession?.headerText }
    var anchorLocation: Int? { activeSession?.anchorLocation }

    /// Whether the active session supports Space-key input validation (e.g. directory pick).
    var hasInputValidation: Bool { activeSession?.validateAndConfirmFromInput != nil }

    // MARK: - Internal State

    private var activeSession: CompletionSession?
    private var text: String = ""
    private var lastQuery: String?
    private var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    private let rules: [any CompletionTriggerRule] = [
        SlashCommandTriggerRule(),
        DirectoryPickTriggerRule(),   // before FileMention: both match "@", directoryPick only when dir==nil
        FileMentionTriggerRule(),
    ]

    // MARK: - CompletionSession

    struct CompletionSession {
        let anchorLocation: Int
        let headerText: String?
        /// Override for empty reason (e.g. `.noDirectory` for slash without provider).
        let emptyReasonOverride: EmptyReason?
        let provider: (_ query: String, _ completion: @escaping ([any CompletionItem]) -> Void) -> Void
        /// Returns text replacement. `keepSession` lets the session distinguish navigation (Tab) from final confirm (Enter).
        /// The `wordEnd` parameter is the end offset of the full trigger word (anchor to next whitespace/EOT).
        let makeReplacement: (_ item: any CompletionItem, _ text: String, _ wordEnd: Int, _ keepSession: Bool) -> (range: NSRange, replacement: String)
        /// Side-effect closure called on final confirm (keepSession=false). Nil for standard text replacement.
        let onItemConfirmed: ((_ item: any CompletionItem) -> Void)?
        /// Validates raw query text (e.g. typed path) and performs side-effects if valid. Returns true if confirmed.
        let validateAndConfirmFromInput: ((_ query: String) -> Bool)?
        /// Custom word range calculation. Returns anchor..<wordEnd. Nil to use default whitespace-based logic.
        let customWordRange: ((_ text: String, _ anchorLocation: Int) -> Range<Int>)?
        /// Transform extracted query before passing to provider (e.g. strip quotes). Nil for identity.
        let transformQuery: ((_ rawQuery: String) -> String)?

        init(anchorLocation: Int,
             headerText: String? = nil,
             emptyReasonOverride: EmptyReason? = nil,
             provider: @escaping (_ query: String, _ completion: @escaping ([any CompletionItem]) -> Void) -> Void,
             makeReplacement: @escaping (_ item: any CompletionItem, _ text: String, _ wordEnd: Int, _ keepSession: Bool) -> (range: NSRange, replacement: String),
             onItemConfirmed: ((_ item: any CompletionItem) -> Void)? = nil,
             validateAndConfirmFromInput: ((_ query: String) -> Bool)? = nil,
             customWordRange: ((_ text: String, _ anchorLocation: Int) -> Range<Int>)? = nil,
             transformQuery: ((_ rawQuery: String) -> String)? = nil) {
            self.anchorLocation = anchorLocation
            self.headerText = headerText
            self.emptyReasonOverride = emptyReasonOverride
            self.provider = provider
            self.makeReplacement = makeReplacement
            self.onItemConfirmed = onItemConfirmed
            self.validateAndConfirmFromInput = validateAndConfirmFromInput
            self.customWordRange = customWordRange
            self.transformQuery = transformQuery
        }
    }

    // MARK: - Word Extraction

    /// Extract the full word after the anchor (from anchor+1 to wordEnd), optionally transformed.
    private func extractQuery(for session: CompletionSession) -> String? {
        let range = wordRange(for: session)
        guard range.upperBound > range.lowerBound + 1 else { return range.upperBound > range.lowerBound ? "" : nil }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound + 1)
        let end = text.index(text.startIndex, offsetBy: range.upperBound)
        let raw = String(text[start..<end])
        if let transform = session.transformQuery {
            return transform(raw)
        }
        return raw
    }

    /// Range of the trigger word in the text: [anchor ... wordEnd].
    /// `wordEnd` is the offset past the last character of the word (like cursor convention).
    private func wordRange(for session: CompletionSession) -> Range<Int> {
        if let custom = session.customWordRange {
            return custom(text, session.anchorLocation)
        }
        return defaultWordRange(anchor: session.anchorLocation)
    }

    /// Default word range: anchor to next whitespace or end of text.
    private func defaultWordRange(anchor: Int) -> Range<Int> {
        guard anchor < text.count else { return anchor..<anchor }
        let afterAnchor = text.index(text.startIndex, offsetBy: anchor + 1)
        let rest = text[afterAnchor...]
        if let spaceIdx = rest.firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            return anchor..<text.distance(from: text.startIndex, to: spaceIdx)
        }
        return anchor..<text.count
    }

    // MARK: - Trigger Detection

    /// Called when text changes. Detects triggers and updates query.
    func checkTrigger(text newText: String, cursorLocation: Int, hasMarkedText: Bool, context: CompletionTriggerContext) {
        guard !hasMarkedText else { return }
        text = newText
        self.cursorLocation = cursorLocation

        guard cursorLocation >= 0, cursorLocation <= text.count else {
            if activeSession != nil { dismiss() }
            return
        }

        // Detect new trigger at current cursor position
        let newSession = detectTrigger(text: text, cursorLocation: cursorLocation, context: context)

        if let active = activeSession {
            // New trigger at a different anchor → replace session
            if let newSession, newSession.anchorLocation != active.anchorLocation {
                dismiss()
                startSession(newSession)
                return
            }

            // Anchor character deleted → dismiss
            if active.anchorLocation >= text.count {
                dismiss()
                if let newSession { startSession(newSession) }
                return
            }

            // Text changed — re-query with full word
            refreshQuery()
            return
        }

        // No active session → start new if trigger found
        if let newSession {
            startSession(newSession)
        }
    }

    /// Iterate trigger rules and return first matching session, or nil.
    private func detectTrigger(text: String, cursorLocation: Int, context: CompletionTriggerContext) -> CompletionSession? {
        guard cursorLocation > 0 else { return nil }
        for rule in rules {
            if let session = rule.match(text: text, cursorLocation: cursorLocation, context: context) {
                return session
            }
        }
        return nil
    }

    private func startSession(_ session: CompletionSession) {
        activeSession = session
        lastQuery = nil

        if let override = session.emptyReasonOverride {
            emptyReason = override
            items = []
            isLoading = false
            if override == .noDirectory { return }
        }

        refreshQuery()
    }

    // MARK: - Query Refresh

    /// Re-extract the full word query from text and call provider if query changed.
    private func refreshQuery() {
        guard let session = activeSession else { return }

        // Anchor out of bounds → dismiss
        guard session.anchorLocation < text.count else {
            dismiss()
            return
        }

        let query = extractQuery(for: session) ?? ""

        // Skip provider call if query hasn't changed
        guard query != lastQuery else { return }
        lastQuery = query

        generation += 1
        let currentGen = generation
        debounceTask?.cancel()

        if query.isEmpty {
            session.provider(query) { [weak self] results in
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGen else { return }
                    self.items = results
                    self.selectedIndex = 0
                    self.isLoading = false
                    self.emptyReason = results.isEmpty ? (session.emptyReasonOverride ?? .noMatches) : .noMatches
                }
            }
        } else {
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.generation == currentGen else { return }

                let loadingTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled, let self, self.generation == currentGen else { return }
                    self.isLoading = true
                    self.emptyReason = .loading
                }

                session.provider(query) { [weak self] results in
                    DispatchQueue.main.async {
                        loadingTask.cancel()
                        guard let self, self.generation == currentGen else { return }
                        self.items = results
                        self.selectedIndex = 0
                        self.isLoading = false
                        self.emptyReason = results.isEmpty ? (session.emptyReasonOverride ?? .noMatches) : .noMatches
                    }
                }
            }
        }
    }

    // MARK: - Confirm

    func confirmSelection(keepSession: Bool = false) -> (range: NSRange, replacement: String)? {
        guard let session = activeSession,
              selectedIndex >= 0, selectedIndex < items.count else { return nil }

        let item = items[selectedIndex]
        let wEnd = wordRange(for: session).upperBound
        let result = session.makeReplacement(item, text, wEnd, keepSession)

        if !keepSession {
            session.onItemConfirmed?(item)
            dismiss()
        }
        return result
    }

    func tryConfirmFromInput() -> NSRange? {
        guard let session = activeSession,
              let validate = session.validateAndConfirmFromInput else { return nil }

        guard let query = extractQuery(for: session), !query.isEmpty else { return nil }
        guard validate(query) else { return nil }

        let wEnd = wordRange(for: session).upperBound
        let range = NSRange(location: session.anchorLocation, length: wEnd - session.anchorLocation)
        dismiss()
        return range
    }

    // MARK: - Item Mutation

    /// Remove items matching a predicate and adjust selectedIndex.
    func removeItem(where predicate: (any CompletionItem) -> Bool) {
        items.removeAll(where: predicate)
        if selectedIndex >= items.count {
            selectedIndex = max(0, items.count - 1)
        }
    }

    // MARK: - Navigation

    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    // MARK: - Dismiss

    func dismiss() {
        activeSession = nil
        lastQuery = nil
        items = []
        selectedIndex = 0
        isLoading = false
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
    }
}
