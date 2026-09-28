import AgentSDK
import Foundation

// MARK: - Side question (/btw)

extension SessionRuntime {

    /// Asks a one-off question about the conversation without interrupting
    /// the running turn; the answer is not added to the transcript. `nil`
    /// when the CLI produced no text. Throws `AgentSDKError.notRunning`
    /// without a live CLI, or the CLI's refusal.
    func askSideQuestion(_ question: String) async throws -> SideQuestionAnswer? {
        guard let cliClient else { throw AgentSDKError.notRunning }
        return try await cliClient.askSideQuestion(question)
    }
}
