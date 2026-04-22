import Foundation

/// 将裸 URL 从纯文本中切出为 `.link` inline。仅识别 `http://` 和 `https://`
/// scheme——file path、email、裸域名（example.com）保持为文本，避免把代码
/// 路径/文件名误识别成链接。
///
/// 调用方（`MarkdownConvert`）负责在 `[…](url)` 内部短路此处理，防止双重
/// linkify。
enum MarkdownAutolink {
    /// 扫描 `text`，返回单个 `.text`（未命中）或 `.text` / `.link` 混合序列。
    static func split(_ text: String) -> [MarkdownInline] {
        guard text.contains("://") else { return [.text(text)] }
        guard let detector = Self.detector else { return [.text(text)] }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = detector.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [MarkdownInline] = []
        var cursor = 0
        for match in matches {
            guard let url = match.url else { continue }
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { continue }

            var range = match.range
            trimTrailingPunctuation(&range, in: ns)
            guard range.length > 0 else { continue }
            guard range.location >= cursor else { continue }

            if range.location > cursor {
                let head = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result.append(.text(head))
            }
            let urlText = ns.substring(with: range)
            result.append(.link(destination: urlText, children: [.text(urlText)]))
            cursor = range.location + range.length
        }

        if result.isEmpty { return [.text(text)] }
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            result.append(.text(tail))
        }
        return result
    }

    // MARK: - Private

    /// `NSDataDetector` 继承自 `NSRegularExpression`，按 Apple 文档对
    /// `matches(in:options:range:)` 是线程安全的——共享一个实例即可。
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// 剥离 URL 尾部的标点。句子里常见的 `visit https://x.com.` 会被 detector
    /// 连句号一起吞；这里把 `.,;:!?` 和不成对的闭合括号还给文本。
    private static func trimTrailingPunctuation(_ range: inout NSRange, in text: NSString) {
        while range.length > 0 {
            let lastIdx = range.location + range.length - 1
            let last = text.substring(with: NSRange(location: lastIdx, length: 1))
            guard let ch = last.first else { break }

            switch ch {
            case ".", ",", ";", ":", "!", "?", "\"", "'":
                range.length -= 1
            case ")", "]", "}":
                let opener: Character = ch == ")" ? "(" : (ch == "]" ? "[" : "{")
                let body = text.substring(with: NSRange(location: range.location, length: range.length - 1))
                let openers = body.reduce(0) { $1 == opener ? $0 + 1 : $0 }
                let closersIn = body.reduce(0) { $1 == ch ? $0 + 1 : $0 }
                if openers > closersIn { return }
                range.length -= 1
            default:
                return
            }
        }
    }
}
