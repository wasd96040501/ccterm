import SwiftUI
import AgentSDK

// MARK: - ToolContentView

/// Renders the content area for each tool type in a permission card.
/// Switches directly on PermissionRequest.toolInput — no intermediate descriptor.
struct ToolContentView: View {
    let request: PermissionRequest

    var body: some View {
        switch request.toolInput {
        case .Bash(let v):
            if let desc = v.input?.description, !desc.isEmpty {
                DescriptionLabel(text: desc, maxLines: 4)
            }
            if let cmd = v.input?.command, !cmd.isEmpty {
                NativeBashView(command: cmd, maxHeight: 300)
            }

        case .Read(let v):
            if let fp = v.input?.filePath, !fp.isEmpty {
                MonoLabel(text: fp, maxLines: 2)
            }

        case .Write(let v):
            if let fp = v.input?.filePath, !fp.isEmpty {
                MonoLabel(text: fp, maxLines: 2)
            }
            let content = v.input?.content ?? ""
            if !content.isEmpty {
                NativeDiffView(filePath: v.input?.filePath ?? "", oldString: "", newString: content)
                    .frame(maxHeight: 300)
            }

        case .Edit(let v):
            if let fp = v.input?.filePath, !fp.isEmpty {
                MonoLabel(text: fp, maxLines: 2)
            }
            let oldStr = v.input?.oldString ?? ""
            let newStr = v.input?.newString ?? ""
            if !oldStr.isEmpty || !newStr.isEmpty {
                NativeDiffView(filePath: v.input?.filePath ?? "", oldString: oldStr, newString: newStr)
                    .frame(maxHeight: 300)
            }

        case .Glob(let v):
            if let pattern = v.input?.pattern, !pattern.isEmpty {
                KeyValueRow(key: "pattern", value: pattern)
            }
            if let path = v.input?.path, !path.isEmpty {
                KeyValueRow(key: "path", value: path)
            }

        case .Grep(let v):
            if let pattern = v.input?.pattern, !pattern.isEmpty {
                KeyValueRow(key: "pattern", value: pattern)
            }
            if let path = v.input?.path, !path.isEmpty {
                KeyValueRow(key: "path", value: path)
            }
            if let glob = v.input?.glob, !glob.isEmpty {
                KeyValueRow(key: "glob", value: glob)
            }

        case .WebFetch(let v):
            if let url = v.input?.url, !url.isEmpty {
                MonoLabel(text: url, maxLines: 2)
            }

        case .WebSearch(let v):
            if let query = v.input?.query, !query.isEmpty {
                MonoLabel(text: query, maxLines: 4)
            }
            let prompt = request.rawInput["prompt"] as? String
            if let prompt, !prompt.isEmpty {
                DescriptionLabel(text: prompt, maxLines: 4)
            }

        default:
            let reason = request.decisionReason?.reason
            let fields = buildGenericFields()
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

    private func buildGenericFields() -> [(key: String, value: String)] {
        var fields: [(key: String, value: String)] = []
        for key in request.rawInput.keys.sorted() {
            if let value = request.rawInput[key] as? String, !value.isEmpty {
                fields.append((key: key, value: value))
            }
        }
        return fields
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
