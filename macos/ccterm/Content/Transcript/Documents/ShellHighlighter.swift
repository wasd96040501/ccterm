import Foundation

/// Tints a shell command the way the design's command card does
/// (02-command.md "Command card"): the command word like inline code, strings
/// in the code card's string colour, variables and comments set apart, flags
/// and arguments left in label colour.
nonisolated enum ShellHighlighter {
    /// A leading `cd <dir> &&`, set in tertiary on its own line: there, but
    /// quiet. `rest` is what remains of the command.
    static func splitDirectoryChange(_ command: String) -> (prefix: String?, rest: String) {
        guard command.hasPrefix("cd "), let range = command.range(of: " && ") else { return (nil, command) }
        let directory = command[command.index(command.startIndex, offsetBy: 3)..<range.lowerBound]
        guard !directory.contains(where: \.isNewline) else { return (nil, command) }
        let rest = String(command[range.upperBound...].drop { $0 == " " })
        return (String(command[..<range.upperBound]).trimmingCharacters(in: .whitespaces), rest)
    }

    static func spans(in text: String) -> [LineSpan] {
        let units = Array(text.utf16)
        var spans: [LineSpan] = []
        var index = 0
        var atCommand = true
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 }
        func endsWord(_ c: UInt16) -> Bool { isSpace(c) || [34, 39, 38, 124, 59].contains(c) }
        while index < units.count {
            let c = units[index]
            let start = index
            if isSpace(c) {
                if c == 10 { atCommand = true }
                index += 1
            } else if c == 34 || c == 39 {
                index += 1
                while index < units.count, units[index] != c { index += units[index] == 92 && c == 34 ? 2 : 1 }
                index = min(index + 1, units.count)
                spans.append(LineSpan(range: start..<index, style: .string))
                atCommand = false
            } else if c == 35 {
                while index < units.count, units[index] != 10 { index += 1 }
                spans.append(LineSpan(range: start..<index, style: .comment))
            } else if c == 38 || c == 124 || c == 59 {  // & | ;
                while index < units.count, [38, 124, 59].contains(units[index]) { index += 1 }
                atCommand = true
            } else if c == 36 {  // $
                index += 1
                while index < units.count, !endsWord(units[index]) { index += 1 }
                spans.append(LineSpan(range: start..<index, style: .type))
            } else {
                while index < units.count, !endsWord(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if atCommand, !word.contains("=") {
                    spans.append(LineSpan(range: start..<index, style: .function))
                    atCommand = false
                }
            }
        }
        return spans
    }
}
