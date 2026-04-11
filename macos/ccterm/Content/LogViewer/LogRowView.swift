import SwiftUI

struct LogRowView: View {
    let entry: LogEntry
    let isEvenRow: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .padding(.leading, 8)

            Image(systemName: entry.level.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(entry.category)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(.primary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "[\(entry.level.label)] [\(entry.category)] \(entry.message)",
                    forType: .string
                )
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                ZStack {
                    Image(systemName: "doc.on.doc")
                        .opacity(copied ? 0 : 1)
                    Image(systemName: "checkmark")
                        .opacity(copied ? 1 : 0)
                        .foregroundStyle(.green)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0)
            .padding(.trailing, 8)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 3)
        .background(rowBackground)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        switch entry.level {
        case .error:
            return colorScheme == .dark
                ? Color(red: 0x3D / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0)
                : Color(red: 0xFD / 255.0, green: 0xE8 / 255.0, blue: 0xE8 / 255.0)
        case .warning:
            return colorScheme == .dark
                ? Color(red: 0x3A / 255.0, green: 0x2E / 255.0, blue: 0x1A / 255.0)
                : Color(red: 0xFE / 255.0, green: 0xF3 / 255.0, blue: 0xE2 / 255.0)
        default:
            if isEvenRow {
                return colorScheme == .dark
                    ? Color(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0)
                    : Color.white
            } else {
                return colorScheme == .dark
                    ? Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0)
                    : Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF5 / 255.0)
            }
        }
    }
}
