import SwiftUI

/// Native SwiftUI unified diff view with syntax highlighting via highlight.js (JSCore).
/// Entire diff is a single Text(AttributedString) — gutter, sign, content all inline.
struct NativeDiffView: View {
    let filePath: String
    let oldString: String
    let newString: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxEngine) private var syntaxEngine

    @State private var hunks: [DiffEngine.Hunk] = []
    @State private var lineHighlights: [String: [SyntaxToken]] = [:]
    @State private var cachedContent: AttributedString = AttributedString(" ")

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(cachedContent)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .fixedSize()
                .textSelection(.enabled)
        }
        .defaultScrollAnchor(.topLeading)
        .scrollIndicators(.automatic)
        .background(DiffColors.tableBg(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(oldString.hashValue)_\(newString.hashValue)") {
            hunks = DiffEngine.computeHunks(old: oldString, new: newString)
            rebuildAttributedContent()

            guard let engine = syntaxEngine else { return }
            let lang = LanguageDetection.language(for: filePath)

            let uniqueContents = Set(hunks.flatMap(\.lines).map(\.content)).filter { !$0.isEmpty }
            for content in uniqueContents {
                let tokens = await engine.highlight(code: content, language: lang)
                lineHighlights[content] = tokens
            }
            rebuildAttributedContent()
        }
        .onChange(of: colorScheme) {
            rebuildAttributedContent()
        }
    }

    // MARK: - AttributedString Builder

    private func rebuildAttributedContent() {
        guard !hunks.isEmpty else {
            cachedContent = AttributedString(" ")
            return
        }

        let maxLineNo = hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let gutterDigits = max(2, String(maxLineNo).count)
        let font = Font.system(size: 12, design: .monospaced)

        // Compute max content width for uniform background padding
        let maxContentLen = hunks.flatMap(\.lines).map(\.content.count).max() ?? 0
        let padToContent = max(maxContentLen, 1)

        var result = AttributedString()

        for (hi, hunk) in hunks.enumerated() {
            if hi > 0 {
                result.append(buildSeparator(gutterDigits: gutterDigits, padTo: padToContent, font: font))
            }
            for line in hunk.lines {
                result.append(buildLine(line, gutterDigits: gutterDigits, padTo: padToContent, font: font))
            }
        }

        // Remove trailing newline
        if !result.characters.isEmpty, result.characters.last == "\n" {
            result.characters.removeLast()
        }

        cachedContent = result
    }

    private func buildLine(
        _ line: DiffEngine.Line,
        gutterDigits: Int,
        padTo: Int,
        font: Font
    ) -> AttributedString {
        let lineNoStr = line.lineNo.map(String.init) ?? ""
        let paddedLineNo = String(repeating: " ", count: max(0, gutterDigits - lineNoStr.count)) + lineNoStr

        let sign: String
        let signColor: Color
        switch line.type {
        case .add:
            sign = "+"; signColor = DiffColors.signAdd(colorScheme)
        case .del:
            sign = "-"; signColor = DiffColors.signDel(colorScheme)
        case .context:
            sign = " "; signColor = .clear
        }

        let gutterBg = DiffColors.gutterBg(line.type, colorScheme)
        let contentBg = DiffColors.contentBg(line.type, colorScheme)

        // Gutter: " {lineNo} "
        var gutter = AttributedString(" \(paddedLineNo) ")
        gutter.font = font
        gutter.foregroundColor = DiffColors.gutterText(colorScheme)
        gutter.backgroundColor = gutterBg

        // Sign: "{sign} "
        var signPart = AttributedString("\(sign) ")
        signPart.font = font
        signPart.foregroundColor = signColor
        signPart.backgroundColor = contentBg

        // Content (highlighted or plain), padded to uniform width
        let rawContent = line.content.isEmpty ? " " : line.content
        let padCount = max(0, padTo - rawContent.count)
        let paddedContent = rawContent + String(repeating: " ", count: padCount)

        var contentPart: AttributedString
        if let tokens = lineHighlights[line.content], !line.content.isEmpty {
            contentPart = SyntaxAttributedString.build(tokens: tokens, colorScheme: colorScheme, font: font)
            // Append padding spaces
            if padCount > 0 {
                var pad = AttributedString(String(repeating: " ", count: padCount))
                pad.font = font
                contentPart.append(pad)
            }
        } else {
            contentPart = AttributedString(paddedContent)
            contentPart.font = font
            contentPart.foregroundColor = SyntaxTheme.plainColor(colorScheme)
        }
        contentPart.backgroundColor = contentBg

        // Trailing space for right padding
        var trailing = AttributedString(" ")
        trailing.font = font
        trailing.backgroundColor = contentBg

        var newline = AttributedString("\n")
        newline.font = font

        return gutter + signPart + contentPart + trailing + newline
    }

    private func buildSeparator(gutterDigits: Int, padTo: Int, font: Font) -> AttributedString {
        let sepBg = DiffColors.separatorBg(colorScheme)
        let sepFg = DiffColors.separatorFg(colorScheme)

        let gutterWidth = gutterDigits + 2 // " {lineNo} "
        let contentWidth = 2 + padTo + 1   // "{sign} {content} "
        let totalWidth = gutterWidth + contentWidth

        let dots = " ··· "
        let remaining = max(0, totalWidth - dots.count)
        let leftPad = remaining / 2
        let rightPad = remaining - leftPad
        let line = String(repeating: " ", count: leftPad) + dots + String(repeating: " ", count: rightPad)

        var sep = AttributedString(line + "\n")
        sep.font = font
        sep.foregroundColor = sepFg
        sep.backgroundColor = sepBg

        return sep
    }
}

// MARK: - Colors

private enum DiffColors {
    static func tableBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 27/255, green: 31/255, blue: 38/255)
            : Color(.sRGB, red: 129/255, green: 139/255, blue: 152/255, opacity: 31/255)
    }

    static func gutterText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 230/255, green: 237/255, blue: 243/255, opacity: 0.4)
            : Color(.sRGB, red: 31/255, green: 35/255, blue: 40/255, opacity: 0.5)
    }

    static func signAdd(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255)
            : Color(.sRGB, red: 26/255, green: 127/255, blue: 55/255)
    }

    static func signDel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255)
            : Color(.sRGB, red: 207/255, green: 34/255, blue: 46/255)
    }

    static func gutterBg(_ type: DiffEngine.Line.LineType, _ scheme: ColorScheme) -> Color {
        switch (type, scheme) {
        case (.add, .dark):     Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.25)
        case (.add, .light):    Color(.sRGB, red: 214/255, green: 236/255, blue: 222/255)
        case (.del, .dark):     Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.25)
        case (.del, .light):    Color(.sRGB, red: 236/255, green: 214/255, blue: 216/255)
        case (.context, .dark): Color.white.opacity(0.04)
        case (.context, .light): Color.black.opacity(0.04)
        default: .clear
        }
    }

    static func contentBg(_ type: DiffEngine.Line.LineType, _ scheme: ColorScheme) -> Color {
        switch (type, scheme) {
        case (.add, .dark):     Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.15)
        case (.add, .light):    Color(.sRGB, red: 230/255, green: 243/255, blue: 235/255)
        case (.del, .dark):     Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.15)
        case (.del, .light):    Color(.sRGB, red: 243/255, green: 230/255, blue: 231/255)
        default: .clear
        }
    }

    static func separatorBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 48/255, green: 54/255, blue: 61/255)
            : Color(.sRGB, red: 209/255, green: 217/255, blue: 224/255)
    }

    static func separatorFg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 230/255, green: 237/255, blue: 243/255, opacity: 0.3)
            : Color(.sRGB, red: 31/255, green: 35/255, blue: 40/255, opacity: 0.4)
    }
}

// MARK: - Diff Engine

enum DiffEngine {

    struct Line {
        enum LineType { case context, add, del }
        let type: LineType
        let content: String
        let lineNo: Int?
    }

    struct Hunk {
        let oldStart: Int
        let newStart: Int
        let lines: [Line]
    }

    static func computeHunks(old: String, new: String, context: Int = 3) -> [Hunk] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        let diff = newLines.difference(from: oldLines)

        var removedSet = Set<Int>()
        var insertedSet = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedSet.insert(offset)
            case .insert(let offset, _, _): insertedSet.insert(offset)
            }
        }

        // Build flat diff output: deletions before insertions at each position
        var flat: [(Character, String)] = []
        var oi = 0, ni = 0
        while oi < oldLines.count || ni < newLines.count {
            while oi < oldLines.count, removedSet.contains(oi) {
                flat.append(("-", oldLines[oi])); oi += 1
            }
            while ni < newLines.count, insertedSet.contains(ni) {
                flat.append(("+", newLines[ni])); ni += 1
            }
            if oi < oldLines.count, ni < newLines.count {
                flat.append((" ", newLines[ni])); oi += 1; ni += 1
            }
        }

        return groupHunks(flat, context: context)
    }

    // MARK: Private

    private static func splitLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func groupHunks(_ lines: [(Character, String)], context: Int) -> [Hunk] {
        let changes = lines.indices.filter { lines[$0].0 != " " }
        guard !changes.isEmpty else { return [] }

        // Merge nearby change groups
        var groups: [(Int, Int)] = []
        var gs = changes[0], ge = changes[0]
        for i in 1..<changes.count {
            if changes[i] - ge <= 2 * context {
                ge = changes[i]
            } else {
                groups.append((gs, ge)); gs = changes[i]; ge = changes[i]
            }
        }
        groups.append((gs, ge))

        return groups.map { group in
            let lo = max(0, group.0 - context)
            let hi = min(lines.count, group.1 + context + 1)

            // Starting line numbers for this hunk
            var oldLine = 1, newLine = 1
            for i in 0..<lo {
                switch lines[i].0 {
                case " ": oldLine += 1; newLine += 1
                case "-": oldLine += 1
                case "+": newLine += 1
                default: break
                }
            }

            var hunkLines: [Line] = []
            var curOld = oldLine, curNew = newLine
            for i in lo..<hi {
                let (ch, content) = lines[i]
                switch ch {
                case " ":
                    hunkLines.append(Line(type: .context, content: content, lineNo: curNew))
                    curOld += 1; curNew += 1
                case "+":
                    hunkLines.append(Line(type: .add, content: content, lineNo: curNew))
                    curNew += 1
                case "-":
                    hunkLines.append(Line(type: .del, content: content, lineNo: curOld))
                    curOld += 1
                default: break
                }
            }

            return Hunk(oldStart: oldLine, newStart: newLine, lines: hunkLines)
        }
    }
}

// MARK: - Previews

private let sampleOld = """
func greet(name: String) {
    print("Hello, \\(name)!")
    print("Welcome.")
}
"""

private let sampleNew = """
func greet(name: String, greeting: String = "Hello") {
    print("\\(greeting), \\(name)!")
    print("Welcome to the app.")
    logger.info("Greeted \\(name)")
}
"""

#Preview("Edit diff") {
    NativeDiffView(filePath: "Sources/Greeter.swift", oldString: sampleOld, newString: sampleNew)
        .padding()
        .frame(width: 500)
}

#Preview("New file (all additions)") {
    NativeDiffView(
        filePath: "config.yaml",
        oldString: "",
        newString: "port: 8080\nhost: localhost\ndebug: true\nlog_level: info"
    )
    .padding()
    .frame(width: 400)
}

#Preview("Delete lines") {
    NativeDiffView(
        filePath: "cleanup.sh",
        oldString: "echo start\nrm -rf /tmp/cache\nrm -rf /tmp/logs\necho done",
        newString: "echo start\necho done"
    )
    .padding()
    .frame(width: 400)
}

#Preview("Dark mode") {
    VStack(spacing: 16) {
        NativeDiffView(filePath: "App.swift", oldString: sampleOld, newString: sampleNew)
        NativeDiffView(filePath: "new.txt", oldString: "", newString: "line 1\nline 2\nline 3")
    }
    .padding()
    .frame(width: 500)
    .preferredColorScheme(.dark)
}

#Preview("Light mode") {
    VStack(spacing: 16) {
        NativeDiffView(filePath: "App.swift", oldString: sampleOld, newString: sampleNew)
        NativeDiffView(filePath: "new.txt", oldString: "", newString: "line 1\nline 2\nline 3")
    }
    .padding()
    .frame(width: 500)
    .preferredColorScheme(.light)
}
