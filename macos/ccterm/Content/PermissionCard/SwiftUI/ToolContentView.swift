import SwiftUI
import WebKit

// MARK: - ToolContentView

/// Renders the content area for each tool type in a permission card.
struct ToolContentView: View {
    let descriptor: ToolContentDescriptor
    /// Pre-loaded WebView loader from ViewModel (avoids flicker on appear).
    var preloadedLoader: WebViewHeightLoader?

    var body: some View {
        switch descriptor {
        case .bash(let description, let command):
            if let desc = description, !desc.isEmpty {
                DescriptionLabel(text: desc, maxLines: 4)
            }
            if let cmd = command, !cmd.isEmpty {
                let loader = preloadedLoader ?? WebViewHeightLoader(
                    htmlResource: "bash-react",
                    bridgeType: "setCommand",
                    bridgeJSON: jsonEncode(["command": cmd]))
                WebContentView(loader: loader, maxHeight: 300)
            }

        case .read(let filePath):
            if let fp = filePath, !fp.isEmpty {
                MonoLabel(text: fp, maxLines: 2)
            }

        case .write(let filePath, let content):
            if let fp = filePath, !fp.isEmpty {
                MonoLabel(text: fp, maxLines: 2)
            }
            if let content, !content.isEmpty {
                let loader = preloadedLoader ?? WebViewHeightLoader(
                    htmlResource: "diff-react",
                    bridgeType: "setDiff",
                    bridgeJSON: jsonEncode(["filePath": filePath ?? "", "oldString": "", "newString": content]))
                WebContentView(loader: loader, maxHeight: 300)
            }

        case .edit(let filePath, let oldString, let newString):
            if let fp = filePath, !fp.isEmpty {
                MonoLabel(text: fp, maxLines: 2)
            }
            if !oldString.isEmpty || !newString.isEmpty {
                let loader = preloadedLoader ?? WebViewHeightLoader(
                    htmlResource: "diff-react",
                    bridgeType: "setDiff",
                    bridgeJSON: jsonEncode(["filePath": filePath ?? "", "oldString": oldString, "newString": newString]))
                WebContentView(loader: loader, maxHeight: 300)
            }

        case .glob(let pattern, let path):
            if let pattern, !pattern.isEmpty {
                KeyValueRow(key: "pattern", value: pattern)
            }
            if let path, !path.isEmpty {
                KeyValueRow(key: "path", value: path)
            }

        case .grep(let pattern, let path, let glob):
            if let pattern, !pattern.isEmpty {
                KeyValueRow(key: "pattern", value: pattern)
            }
            if let path, !path.isEmpty {
                KeyValueRow(key: "path", value: path)
            }
            if let glob, !glob.isEmpty {
                KeyValueRow(key: "glob", value: glob)
            }

        case .webFetch(let url):
            if let url, !url.isEmpty {
                MonoLabel(text: url, maxLines: 2)
            }

        case .webSearch(let query, let prompt):
            if let query, !query.isEmpty {
                MonoLabel(text: query, maxLines: 4)
            }
            if let prompt, !prompt.isEmpty {
                DescriptionLabel(text: prompt, maxLines: 4)
            }

        case .generic(let reason, let fields):
            if let reason, !reason.isEmpty {
                DescriptionLabel(text: reason, maxLines: 6)
            }
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                KeyValueRow(key: field.key, value: field.value)
            }
            if fields.isEmpty && (reason == nil || reason!.isEmpty) {
                DescriptionLabel(text: "Claude wants to use this tool", maxLines: 2)
            }
        }
    }
}

// MARK: - Helper Components

struct MonoLabel: View {
    let text: String
    let maxLines: Int

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(maxLines)
            .textSelection(.enabled)
    }
}

struct DescriptionLabel: View {
    let text: String
    let maxLines: Int

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(maxLines)
            .textSelection(.enabled)
    }
}

func jsonEncode(_ dict: [String: String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let str = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(key):")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(6)
                .textSelection(.enabled)
        }
    }
}
