import Foundation

/// The answer to ``Session/askSideQuestion(_:)``.
public struct SideQuestionAnswer: Sendable, Equatable {
    public var response: String
    /// `true` when the text is the CLI's note about a failed answer (the
    /// model tried to use a tool, or the API call failed) rather than an
    /// answer.
    public var synthetic: Bool

    public init(response: String, synthetic: Bool) {
        self.response = response
        self.synthetic = synthetic
    }
}
