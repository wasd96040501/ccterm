import SwiftUI
import WebKit
import Observation
import AgentSDK

@Observable
final class StandardCardViewModel {
    let request: PermissionRequest
    let toolName: String
    let content: ToolContentDescriptor
    /// Pre-loaded WebView loader (created eagerly to avoid flicker when the card appears).
    let webViewLoader: WebViewHeightLoader?
    private let onDecision: (PermissionDecision) -> Void

    init(request: PermissionRequest, onDecision: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.toolName = request.toolName
        let content = ToolContentDescriptor.from(request)
        self.content = content
        self.webViewLoader = Self.makeLoader(for: content)
        self.onDecision = onDecision
    }

    private static func makeLoader(for content: ToolContentDescriptor) -> WebViewHeightLoader? {
        switch content {
        case .bash(_, let command):
            guard let cmd = command, !cmd.isEmpty else { return nil }
            return WebViewHeightLoader(
                htmlResource: "bash-react",
                bridgeType: "setCommand",
                bridgeJSON: jsonEncode(["command": cmd]))
        case .write(let filePath, let newContent):
            guard let newContent, !newContent.isEmpty else { return nil }
            return WebViewHeightLoader(
                htmlResource: "diff-react",
                bridgeType: "setDiff",
                bridgeJSON: jsonEncode(["filePath": filePath ?? "", "oldString": "", "newString": newContent]))
        case .edit(let filePath, let oldString, let newString):
            guard !oldString.isEmpty || !newString.isEmpty else { return nil }
            return WebViewHeightLoader(
                htmlResource: "diff-react",
                bridgeType: "setDiff",
                bridgeJSON: jsonEncode(["filePath": filePath ?? "", "oldString": oldString, "newString": newString]))
        default:
            return nil
        }
    }

    /// Primary confirm action (also used by Cmd+Return).
    func confirm() { onDecision(request.allowOnce()) }

    func allowAlways() { onDecision(request.allowAlways()) }

    func deny(feedback: String? = nil) {
        if let feedback, !feedback.isEmpty {
            onDecision(request.deny(feedback: feedback))
        } else {
            onDecision(request.deny())
        }
    }
}
