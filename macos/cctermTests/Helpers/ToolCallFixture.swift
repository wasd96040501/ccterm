import AgentSDK
import DisplayModels
import Foundation

@testable import ccterm

/// One synthetic tool call, with its result, for tests of what a document
/// says about a call.
enum ToolCallFixture {
    static func call(
        _ name: String, _ input: String, id: String = "c1", state: ToolCallState = .done, text: String = "ok",
        isError: Bool = false, output: String? = nil, hasResult: Bool = true, duration: TimeInterval? = nil
    ) -> ToolCall {
        let use = ToolUseBlock(id: id, name: name, input: MessageScript.json(input))
        let result: UserMessage? =
            hasResult
            ? UserMessage(
                content: [.toolResult(ToolResultBlock(toolUseID: id, content: [.text(text)], isError: isError))],
                toolUseResult: output.map(MessageScript.json), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
            : nil
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        return ToolCall(
            use: use, result: result, kind: ToolKind(use, result: result), state: state, startedAt: started,
            finishedAt: duration.map { started.addingTimeInterval($0) })
    }

    /// A finished Bash call.
    static func bash(
        _ command: String, description: String? = nil, stdout: String = "", stderr: String = "",
        interpretation: String? = nil, persisted: String? = nil, sandboxOff: Bool = false, duration: TimeInterval? = 3
    ) -> ToolCall {
        var input: [String: Any] = ["command": command]
        if let description { input["description"] = description }
        if sandboxOff { input["dangerouslyDisableSandbox"] = true }
        var output: [String: Any] = ["stdout": stdout, "stderr": stderr, "interrupted": false]
        if let persisted { output["persistedOutputPath"] = persisted }
        if let interpretation { output["returnCodeInterpretation"] = interpretation }
        return call("Bash", json(input), output: json(output), duration: duration)
    }

    /// A Bash call that exited non-zero.
    static func failedBash(
        _ command: String, description: String? = nil, exit: Int = 65, output: String, duration: TimeInterval? = 48
    ) -> ToolCall {
        var input: [String: Any] = ["command": command]
        if let description { input["description"] = description }
        let message = "Exit code \(exit)\n\(output)"
        return call(
            "Bash", json(input), state: .failed(message: message), text: message, isError: true, duration: duration)
    }

    /// A finished Edit with the hunks the CLI recorded.
    static func edit(
        _ path: String, old: String, new: String, hunks: [[String: Any]], originalFile: String? = nil
    ) -> ToolCall {
        var output: [String: Any] = [
            "filePath": path, "oldString": old, "newString": new, "structuredPatch": hunks,
        ]
        if let originalFile { output["originalFile"] = originalFile }
        return call(
            "Edit", json(["file_path": path, "old_string": old, "new_string": new]), output: json(output))
    }

    static func hunk(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) -> [String: Any] {
        ["oldStart": oldStart, "oldLines": oldLines, "newStart": newStart, "newLines": newLines, "lines": lines]
    }

    /// A finished Write of a new file.
    static func write(_ path: String, content: String) -> ToolCall {
        call(
            "Write", json(["file_path": path, "content": content]),
            output: json(["type": "create", "filePath": path, "content": content, "structuredPatch": []]))
    }

    /// A finished Read of a slice of a text file.
    static func read(_ path: String, content: String, startLine: Int, total: Int) -> ToolCall {
        let count = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return call(
            "Read", json(["file_path": path, "offset": startLine]),
            output: json([
                "type": "text",
                "file": [
                    "filePath": path, "content": content, "numLines": count, "startLine": startLine,
                    "totalLines": total,
                ],
            ]))
    }

    static func json(_ object: Any) -> String {
        String(
            decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(),
            as: UTF8.self)
    }
}
