import SwiftUI

/// Native SwiftUI unified diff view with syntax highlighting via highlight.js (JSCore).
struct NativeDiffView: View {
    let filePath: String
    let oldString: String
    let newString: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxEngine) private var syntaxEngine

    @State private var hunks: [DiffEngine.Hunk] = []
    @State private var lineHighlights: [String: [SyntaxToken]] = [:]

    var body: some View {
        let flatItems = buildFlatItems()
        let maxLineNo = hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let gutterChars = max(2, String(maxLineNo).count)
        // 1ch ≈ 7.2pt at 12pt monospace; gutter = (digits + 2) × ch
        let gutterWidth = CGFloat(gutterChars + 2) * 7.2

        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(flatItems) { item in
                    switch item.kind {
                    case .line(let line, let isFirst, let isLast):
                        DiffLineRow(
                            line: line,
                            gutterWidth: gutterWidth,
                            colorScheme: colorScheme,
                            highlightedContent: highlightedAttributedString(for: line.content),
                            isFirst: isFirst,
                            isLast: isLast
                        )
                    case .separator:
                        hunkSeparator
                    }
                }
            }
        }
        .textSelection(.enabled)
        .background(DiffTheme.tableBg(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(oldString.hashValue)_\(newString.hashValue)") {
            hunks = DiffEngine.computeHunks(old: oldString, new: newString)

            guard let engine = syntaxEngine else { return }
            let lang = LanguageDetection.language(for: filePath)

            // Collect unique line contents to highlight
            let uniqueContents = Set(hunks.flatMap(\.lines).map(\.content)).filter { !$0.isEmpty }
            for content in uniqueContents {
                let tokens = await engine.highlight(code: content, language: lang)
                lineHighlights[content] = tokens
            }
        }
    }

    private func highlightedAttributedString(for content: String) -> AttributedString? {
        guard let tokens = lineHighlights[content] else { return nil }
        return SyntaxAttributedString.build(
            tokens: tokens,
            colorScheme: colorScheme,
            font: .system(size: 12, design: .monospaced)
        )
    }

    /// Flatten hunks into a single array with stable IDs, tracking first/last positions.
    private func buildFlatItems() -> [DiffDisplayItem] {
        var items: [DiffDisplayItem] = []
        var index = 0
        for (hi, hunk) in hunks.enumerated() {
            if hi > 0 {
                items.append(DiffDisplayItem(id: index, kind: .separator))
                index += 1
            }
            for (li, line) in hunk.lines.enumerated() {
                let isFirst = (hi == 0 && li == 0)
                let isLast = (hi == hunks.count - 1 && li == hunk.lines.count - 1)
                items.append(DiffDisplayItem(id: index, kind: .line(line, isFirst: isFirst, isLast: isLast)))
                index += 1
            }
        }
        return items
    }

    private var hunkSeparator: some View {
        let bg = colorScheme == .dark
            ? Color(.sRGB, red: 48/255, green: 54/255, blue: 61/255)   // #30363d
            : Color(.sRGB, red: 209/255, green: 217/255, blue: 224/255) // #d1d9e0
        let fg = colorScheme == .dark
            ? Color(.sRGB, red: 230/255, green: 237/255, blue: 243/255).opacity(0.3)
            : Color(.sRGB, red: 31/255, green: 35/255, blue: 40/255).opacity(0.4)

        return Text("···")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(fg)
            .tracking(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(bg)
    }
}

// MARK: - Display Item

private struct DiffDisplayItem: Identifiable {
    let id: Int
    let kind: Kind

    enum Kind {
        case line(DiffEngine.Line, isFirst: Bool, isLast: Bool)
        case separator
    }
}

// MARK: - Line Row

private struct DiffLineRow: View {
    let line: DiffEngine.Line
    let gutterWidth: CGFloat
    let colorScheme: ColorScheme
    let highlightedContent: AttributedString?
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Gutter (line number)
            Text(line.lineNo.map(String.init) ?? "")
                .foregroundStyle(DiffTheme.gutterText(colorScheme))
                .monospacedDigit()
                .frame(width: gutterWidth, alignment: .trailing)

            // Sign (+/-)
            Text(signText)
                .foregroundStyle(signColor)
                .frame(width: 18, alignment: .center)
                .padding(.leading, 2)

            // Content
            contentView
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.trailing, 10)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(3)
        .padding(.top, isFirst ? 4 : 0)
        .padding(.bottom, isLast ? 4 : 0)
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Rectangle().fill(gutterBg).frame(width: gutterWidth)
                Rectangle().fill(contentBg)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let highlighted = highlightedContent {
            Text(highlighted)
        } else {
            Text(line.content.isEmpty ? " " : line.content)
        }
    }

    private var signText: String {
        switch line.type {
        case .add: "+"; case .del: "-"; case .context: ""
        }
    }

    private var signColor: Color {
        switch (line.type, colorScheme) {
        case (.add, .dark):  Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255)  // #3fb950
        case (.add, .light): Color(.sRGB, red: 26/255, green: 127/255, blue: 55/255)  // #1a7f37
        case (.del, .dark):  Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255)  // #f85149
        case (.del, .light): Color(.sRGB, red: 207/255, green: 34/255, blue: 46/255)  // #cf222e
        default: .clear
        }
    }

    private var gutterBg: Color {
        switch (line.type, colorScheme) {
        case (.add, .dark):  Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.25)
        case (.add, .light): Color(.sRGB, red: 214/255, green: 236/255, blue: 222/255) // #d6ecde
        case (.del, .dark):  Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.25)
        case (.del, .light): Color(.sRGB, red: 236/255, green: 214/255, blue: 216/255) // #ecd6d8
        case (.context, .dark):  Color.white.opacity(0.04)
        case (.context, .light): Color.black.opacity(0.04)
        default: .clear
        }
    }

    private var contentBg: Color {
        switch (line.type, colorScheme) {
        case (.add, .dark):  Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.15)
        case (.add, .light): Color(.sRGB, red: 230/255, green: 243/255, blue: 235/255) // #e6f3eb
        case (.del, .dark):  Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.15)
        case (.del, .light): Color(.sRGB, red: 243/255, green: 230/255, blue: 231/255) // #f3e6e7
        default: .clear
        }
    }
}

// MARK: - Theme

private enum DiffTheme {
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
