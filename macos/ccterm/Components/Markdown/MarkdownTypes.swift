import Foundation

public enum MarkdownSegment: Hashable, Sendable {
    case markdown([MarkdownBlock])
    case heading(level: Int, inlines: [MarkdownInline])
    case codeBlock(MarkdownCodeBlock)
    case table(MarkdownTable)
    case mathBlock(String)
    case thematicBreak
}

public indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, children: [MarkdownInline])
    case blockquote([MarkdownBlock])
    case list(MarkdownList)
}

public struct MarkdownList: Hashable, Sendable {
    public let ordered: Bool
    public let startIndex: Int?
    public let items: [MarkdownListItem]

    public init(ordered: Bool, startIndex: Int?, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.startIndex = startIndex
        self.items = items
    }
}

public struct MarkdownListItem: Hashable, Sendable {
    public enum Checkbox: Hashable, Sendable { case checked, unchecked }

    public let checkbox: Checkbox?
    public let content: [MarkdownBlock]

    public init(checkbox: Checkbox?, content: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.content = content
    }
}

public indirect enum MarkdownInline: Hashable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: String, children: [MarkdownInline])
    case image(source: String, alt: String)
    case inlineMath(String)
    case lineBreak
    case softBreak
}

public struct MarkdownCodeBlock: Hashable, Sendable {
    public let language: String?
    public let code: String

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case none, left, center, right }

    public let header: [[MarkdownInline]]
    public let alignments: [Alignment]
    public let rows: [[[MarkdownInline]]]

    public init(header: [[MarkdownInline]], alignments: [Alignment], rows: [[[MarkdownInline]]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}
