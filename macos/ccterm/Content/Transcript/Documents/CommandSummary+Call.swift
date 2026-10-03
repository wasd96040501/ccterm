import AgentSDK
import DisplayModels
import Foundation

/// A command's document, worded from its call or its `!` command: the
/// summary's values are `DisplayModels`', the SDK's tool types are read here.
nonisolated extension CommandSummary {
    // MARK: - A call

    init(_ call: ToolCall) {
        self.init()
        let input = call.use.input(as: Tools.Bash.self)
        let description = input?.description ?? call.use.input["description"]?.stringValue
        heading = description.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Command")
        command = input?.command ?? call.use.input["command"]?.stringValue ?? ""
        warning = input?.dangerouslyDisableSandbox == true ? String(localized: "Sandbox off") : nil

        var facts: [StyledText] = []
        var output: Tools.Bash.Output?
        var text: String?
        switch call.state {
        case .failed(let message):
            let (code, rest) = Self.exitCode(of: message)
            if Self.timedOut(message), let timeout = input?.timeout {
                facts.append(
                    StyledText(
                        String(localized: "Timed out after \((TimeInterval(timeout) / 1000).durationText)"),
                        style: .failure))
            } else {
                var failed = StyledText(String(localized: "Failed"), style: .failure)
                if let code { failed.append(StyledText(" · " + String(localized: "exit \(code)"))) }
                facts.append(failed)
            }
            text = rest
        case .preparing:
            facts.append(StyledText(String(localized: "Preparing")))
            hasOutputArea = false
        case .waiting:
            facts.append(StyledText(String(localized: "Waiting for your approval")))
            hasOutputArea = false
        case .running:
            facts.append(StyledText(String(localized: "Running")))
            isRunning = true
        case .background:
            facts.append(StyledText(String(localized: "Running in background")))
        case .denied:
            facts.append(StyledText(String(localized: "Denied")))
            hasOutputArea = false
        case .interrupted:
            facts.append(StyledText(String(localized: "Interrupted")))
        case .done:
            break
        }
        if case .success(let bash)? = call.result?.toolOutcome(Tools.Bash.self) {
            output = bash
            if bash.interrupted, call.state != .interrupted {
                facts.append(StyledText(String(localized: "Interrupted")))
            }
        }
        let settled: Bool =
            switch call.state {
            case .done, .failed: true
            default: false
            }
        if settled, let duration = call.duration {
            let time = duration.durationText
            facts.append(StyledText(call.ranInBackground ? String(localized: "Background · \(time)") : time))
        }
        status = StyledText.joined(facts, separator: " · ")

        if let output {
            stdout = output.isImage ? "" : output.stdout
            stderr = Self.commandsOwn(stderr: output.stderr)
            note = output.returnCodeInterpretation
            persistedPath = output.persistedOutputPath
            if persistedPath != nil {
                persistedNote = String(localized: "Output was too long to keep here. The full output is in")
            }
            if output.isImage { emptyNote = String(localized: "The output is an image.") }
        } else if let text {
            stdout = text
        } else if let recorded = call.result?.toolResult?.content.compactMap(\.text).joined(separator: "\n"),
            !recorded.isEmpty
        {
            stdout = recorded
        }
        finishEmptyNote()
    }

    // MARK: - A `!` command

    init(_ local: LocalCommand) {
        self.init()
        heading = String(localized: "You ran")
        switch local.command {
        case .shell(let line): command = line
        case .slash(let name, let arguments): command = arguments.isEmpty ? name : name + " " + arguments
        }
        status = StyledText(String(localized: "Local"))
        stdout = local.output
        stderr = local.errorOutput
        finishEmptyNote()
    }

    private mutating func finishEmptyNote() {
        guard hasOutputArea else { return }
        if isRunning {
            emptyNote = String(localized: "Output appears when the command finishes.")
        } else if emptyNote == nil, stdout.isEmpty, stderr.isEmpty {
            emptyNote = String(localized: "No output")
        }
    }

    /// The CLI's note that it moved the shell back after a command left the
    /// project answers no question the reader has (02-command.md "Output").
    private static let directoryResetNote = "Shell cwd was reset to "

    /// `stderr` without the CLI's own note, and without the blank lines
    /// around what is left.
    private static func commandsOwn(stderr: String) -> String {
        stderr.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(directoryResetNote) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// The exit code a failed Bash result names on its first line, and the
    /// output after it.
    private static func exitCode(of message: String) -> (Int?, String) {
        let cleaned = message.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
        let lines = cleaned.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("Exit code "), let code = Int(first.dropFirst(10)) else {
            return (nil, cleaned)
        }
        return (code, lines.dropFirst().joined(separator: "\n"))
    }

    private static func timedOut(_ message: String) -> Bool {
        message.lowercased().contains("timed out")
    }
}
