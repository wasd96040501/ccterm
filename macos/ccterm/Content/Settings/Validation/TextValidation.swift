import Combine
import Foundation

/// Checks a text field's value while it is typed, and applies it only once it
/// is known good.
///
/// A change is checked after typing pauses; until then ``state`` keeps
/// describing the value it was last computed for, and only when the check
/// starts does it turn ``State/checking`` — unless the answer is already
/// known, which shows at once. ``commit(_:apply:)`` — Return or leaving the
/// field — skips the wait. Whatever the check returns for a value that is no
/// longer the text is dropped.
@MainActor
final class TextValidation<Valid> {
    enum State {
        /// The current value is being checked, or has not been yet.
        case checking
        case valid(Valid)
        /// A short reason, ready to show.
        case invalid(String)
    }

    @Published private(set) var state: State

    /// Whether the text as it stands now has been checked and is good.
    var isValid: Bool {
        guard stateText == text, case .valid = state else { return false }
        return true
    }

    private let debounce: Duration
    private let cached: (String) -> State?
    private let check: (String) async -> State
    private var text: String
    /// The value ``state`` was computed for.
    private var stateText: String
    /// Counts changes of the text, to drop answers about an earlier one.
    private var revision = 0
    private var pending: (text: String, apply: (String) -> Void)?
    private var waiting: Task<Void, Never>?
    private var isWaiting = false

    /// `text`: the value the field starts with. `cached`: the answer for a
    /// value if it is already known; `check`: works it out — a `.valid` or
    /// `.invalid`, never `.checking`. `debounce`: how long typing must pause
    /// before a check starts.
    init(
        text: String, debounce: Duration = .milliseconds(500), cached: @escaping (String) -> State?,
        check: @escaping (String) async -> State
    ) {
        self.text = text
        stateText = text
        self.debounce = debounce
        self.cached = cached
        self.check = check
        if let known = cached(text) {
            state = known
        } else {
            state = .checking
            start(text)
        }
    }

    /// The field's text changed. A change of the value drops a commit that was
    /// waiting on the answer.
    func textDidChange(_ newText: String) {
        guard newText != text else { return }
        text = newText
        revision += 1
        pending = nil
        waiting?.cancel()
        isWaiting = false
        if let known = cached(newText) {
            stateText = newText
            state = known
            return
        }
        let revision = revision
        isWaiting = true
        waiting = Task { [weak self, debounce] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            await self?.run(newText, revision: revision)
        }
    }

    /// The person is done with `newText`: `apply` it when it is known good —
    /// now, or as soon as its check says so. A value that turns out invalid,
    /// or a change of the text first, drops it.
    func commit(_ newText: String, apply: @escaping (String) -> Void) {
        textDidChange(newText)
        if stateText == newText {
            if case .valid = state { apply(newText) }
            if case .checking = state { pending = (newText, apply) }
            return
        }
        pending = (newText, apply)
        if isWaiting {
            waiting?.cancel()
            let revision = revision
            waiting = Task { [weak self] in await self?.run(newText, revision: revision) }
        }
    }

    private func start(_ text: String) {
        let revision = revision
        waiting = Task { [weak self] in await self?.run(text, revision: revision) }
    }

    private func run(_ checked: String, revision: Int) async {
        guard revision == self.revision else { return }
        isWaiting = false
        stateText = checked
        state = .checking
        let answer = await check(checked)
        guard revision == self.revision else { return }
        state = answer
        guard let pending, pending.text == checked else { return }
        self.pending = nil
        if case .valid = answer { pending.apply(checked) }
    }
}

extension TextValidation.State: Equatable where Valid: Equatable {}
