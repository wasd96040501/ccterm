import Foundation

/// The environment the user's interactive login shell gives a process.
enum ShellEnvironment {

    /// What one shell run reported.
    struct Probe {
        var environment: [String: String]
        /// The alias `word` expands to, unquoted; `nil` when it is not one.
        var alias: String?
    }

    /// Loads the full environment from a login shell. Re-runs on every call so the freshest shell config is picked up.
    static func loginEnvironment() -> [String: String]? {
        probe(aliasFor: nil)?.environment
    }

    /// The login environment and, for `aliasFor`, its alias definition — both
    /// from one `-li` spawn, since sourcing the rc files is the cost. `nil`
    /// when the shell fails to run or prints no environment. Blocking.
    static func probe(aliasFor word: String?) -> Probe? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        var script = "env"
        if let word {
            script += "; printf '\\n\(aliasMarker)\\n'; alias -- \(CustomCommand.quote(word)) 2>/dev/null; true"
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-li", "-c", script]
        let pipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        return parse(output, aliasFor: word)
    }

    static let aliasMarker = "__CCTERM_ALIAS__"

    /// Splits a probe's output at the alias marker and reads both halves.
    static func parse(_ output: String, aliasFor word: String?) -> Probe? {
        var environmentText = output
        var aliasText: String?
        if let marker = output.range(of: "\n\(aliasMarker)\n", options: .backwards) {
            environmentText = String(output[..<marker.lowerBound])
            aliasText = String(output[marker.upperBound...])
        }
        let environment = parseEnvironment(environmentText)
        guard !environment.isEmpty else { return nil }
        let alias = word.flatMap { word in aliasText.flatMap { parseAlias($0, word: word) } }
        return Probe(environment: environment, alias: alias)
    }

    /// `KEY=value` lines; a line without `=` is skipped.
    static func parseEnvironment(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            env[String(line[line.startIndex..<eqIndex])] = String(line[line.index(after: eqIndex)...])
        }
        return env
    }

    /// The body of alias `word` from `alias -- word` output: zsh prints
    /// `word='body'` or `word=body`, bash `alias word='body'`; a `'` inside the
    /// body arrives as `'\''`. `nil` when the output defines no such alias.
    static func parseAlias(_ output: String, word: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("alias ") { text = String(text.dropFirst("alias ".count)) }
        let prefix = word + "="
        guard text.hasPrefix(prefix) else { return nil }
        let chars = Array(text.dropFirst(prefix.count))
        var index = 0
        var body = ""
        // One shell word, but whitespace inside it is part of the body.
        while index < chars.count {
            switch chars[index] {
            case "'":
                index += 1
                while index < chars.count, chars[index] != "'" {
                    body.append(chars[index])
                    index += 1
                }
                index += 1
            case "\\" where index + 1 < chars.count:
                body.append(chars[index + 1])
                index += 2
            default:
                body.append(chars[index])
                index += 1
            }
        }
        return body
    }
}
