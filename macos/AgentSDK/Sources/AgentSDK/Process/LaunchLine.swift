import Foundation

/// One shell launch line read into its parts:
/// `[export] K=v … [env K=v …] [command [arguments…]]`.
///
/// Values are unquoted (`"…"`, `'…'` or bare) and a value that starts with
/// `~/` gets the home directory. Nothing is executed or expanded beyond that:
/// `$VAR` and command substitutions stay as written.
public struct LaunchLine: Sendable, Equatable {
    /// The leading assignments, in the order written; a later one for the same
    /// name wins, as in the shell.
    public let variables: [(name: String, value: String)]
    /// The command word, unquoted; `nil` when the line is only assignments.
    public let command: String?
    /// Everything after the command word, as written and trimmed; `nil` when
    /// there is none.
    public let arguments: String?

    /// `nil` when `line` is empty or whitespace.
    public init?(_ line: String) {
        let chars = Array(line)
        var index = 0
        Self.skipSpace(chars, &index)
        guard index < chars.count else { return nil }

        if Self.peekWord(chars, index) == "export" {
            index += "export".count
            Self.skipSpace(chars, &index)
        }
        var variables: [(name: String, value: String)] = []
        var command: String?
        var arguments: String?
        var sawEnv = false
        while true {
            Self.skipSpace(chars, &index)
            guard index < chars.count else { break }
            if let (name, valueStart) = Self.assignment(chars, index) {
                index = valueStart
                variables.append((name, Self.readValue(chars, &index)))
            } else if !sawEnv, Self.peekWord(chars, index) == "env" {
                sawEnv = true
                index += "env".count
            } else {
                command = Self.readWord(chars, &index)
                let rest = String(chars[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
                arguments = rest.isEmpty ? nil : rest
                break
            }
        }
        self.variables = variables
        self.command = command
        self.arguments = arguments
    }

    public static func == (lhs: LaunchLine, rhs: LaunchLine) -> Bool {
        lhs.command == rhs.command && lhs.arguments == rhs.arguments
            && lhs.variables.elementsEqual(rhs.variables) { $0.name == $1.name && $0.value == $1.value }
    }

    // MARK: - Reading

    /// Reads one shell word from `index`, removing its quotes; stops at
    /// unquoted whitespace. An unterminated quote runs to the end.
    static func readWord(_ chars: [Character], _ index: inout Int) -> String {
        var word = ""
        while index < chars.count, !chars[index].isWhitespace {
            switch chars[index] {
            case "'":
                index += 1
                while index < chars.count, chars[index] != "'" {
                    word.append(chars[index])
                    index += 1
                }
                index = min(index + 1, chars.count)
            case "\"":
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count, "\"\\$`".contains(chars[index + 1]) {
                        index += 1
                    }
                    word.append(chars[index])
                    index += 1
                }
                index = min(index + 1, chars.count)
            case "\\":
                if index + 1 < chars.count { word.append(chars[index + 1]) }
                index = min(index + 2, chars.count)
            default:
                word.append(chars[index])
                index += 1
            }
        }
        return word
    }

    /// A word read as an assignment's value: `~/` at its start is the home
    /// directory.
    private static func readValue(_ chars: [Character], _ index: inout Int) -> String {
        let start = index
        let value = readWord(chars, &index)
        let tilde = start < chars.count && chars[start] == "~" && start + 1 < chars.count && chars[start + 1] == "/"
        guard tilde else { return value }
        return FileManager.default.homeDirectoryForCurrentUser.path + value.dropFirst()
    }

    private static func skipSpace(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    /// The raw text from `index` to the next whitespace.
    private static func peekWord(_ chars: [Character], _ index: Int) -> String {
        String(chars[index...].prefix { !$0.isWhitespace })
    }

    /// `NAME=` at `index`: the name and where its value starts.
    private static func assignment(_ chars: [Character], _ index: Int) -> (String, Int)? {
        var end = index
        while end < chars.count, chars[end].isASCII,
            chars[end].isLetter || chars[end] == "_" || (end > index && chars[end].isNumber)
        {
            end += 1
        }
        guard end > index, end < chars.count, chars[end] == "=" else { return nil }
        return (String(chars[index..<end]), end + 1)
    }
}
