import Components
import Foundation

/// A configuration folder being typed, checked by looking for it on disk after
/// typing pauses, like a launch command. It has no value to carry: valid means
/// empty or an existing folder.
typealias FolderValidation = TextValidation<Void>

extension TextValidation where Valid == Void {
    /// `text`: the folder the field starts with.
    convenience init(text: String, debounce: Duration = .milliseconds(500)) {
        self.init(
            text: text, debounce: debounce, cached: { _ in nil }, check: { Self.state(of: $0) })
    }

    /// ``State/detail(fallback:)`` for the current state.
    func detail(fallback: String?) -> ValidationDetail { state.detail(fallback: fallback) }

    private static func state(of path: String) -> State {
        LaunchPreferences.folderProblem(path).map(State.invalid) ?? .valid(())
    }
}

extension TextValidation.State where Valid == Void {
    /// What a check says under the field: what the folder holds, or why it
    /// can't be used — with `fallback`, the folder that stays in use, when
    /// there is one.
    func detail(fallback: String?) -> ValidationDetail {
        switch self {
        case .checking: .checking
        case .valid:
            ValidationDetail(text: String(localized: "Claude Code’s settings, sign-in and sessions"), isError: false)
        case .invalid(let reason): .problem(reason, fallback: fallback)
        }
    }
}
