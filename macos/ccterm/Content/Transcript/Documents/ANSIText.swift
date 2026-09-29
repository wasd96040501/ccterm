import Foundation

/// A command's output with its ANSI escape sequences read: the plain lines,
/// and where SGR asked for bold, green or red (02-command.md "Output").
/// Every other sequence — other colours, cursor moves, titles — is dropped.
nonisolated struct ANSIText: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        var text: String
        var spans: [LineSpan]
    }

    /// A trailing newline does not make a line of its own.
    private(set) var lines: [Line]

    init(_ output: String) {
        var lines: [Line] = []
        var text: [UInt16] = []
        var spans: [LineSpan] = []
        var bold = false
        var color: LineSpan.Style?
        var runStart = 0

        func closeRun() {
            let style: LineSpan.Style? =
                switch (bold, color) {
                case (true, .green?): .boldGreen
                case (_, .green?): .green
                case (_, .red?): .red
                case (true, _): .bold
                default: nil
                }
            if let style, runStart < text.count { spans.append(LineSpan(range: runStart..<text.count, style: style)) }
            runStart = text.count
        }
        func endLine() {
            closeRun()
            lines.append(Line(text: String(decoding: text, as: UTF16.self), spans: spans))
            text = []
            spans = []
            runStart = 0
        }

        let units = Array(output.utf16)
        var index = 0
        while index < units.count {
            let c = units[index]
            if c == 27, index + 1 < units.count, units[index + 1] == 91 {  // ESC [
                var end = index + 2
                while end < units.count, !(64...126).contains(units[end]) { end += 1 }
                if end < units.count, units[end] == 109 {  // m
                    closeRun()
                    let parameters = String(decoding: units[(index + 2)..<end], as: UTF16.self)
                    let codes = parameters.isEmpty ? [0] : parameters.split(separator: ";").map { Int($0) ?? -1 }
                    for code in codes {
                        switch code {
                        case 0:
                            bold = false
                            color = nil
                        case 1: bold = true
                        case 22: bold = false
                        case 31, 91: color = .red
                        case 32, 92: color = .green
                        case 30...37, 39, 90...97: color = nil
                        default: break
                        }
                    }
                }
                index = min(end + 1, units.count)
            } else if c == 27 || c == 13 {
                index += 1
            } else if c == 10 {
                endLine()
                index += 1
            } else {
                text.append(c)
                index += 1
            }
        }
        if !text.isEmpty { endLine() }
        self.lines = lines
    }
}
