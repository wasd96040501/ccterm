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

    private static func state(of path: String) -> State {
        LaunchPreferences.folderProblem(path).map(State.invalid) ?? .valid(())
    }
}
