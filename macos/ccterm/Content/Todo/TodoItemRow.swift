import SwiftUI

private let todoItemTitleFont = Font.system(size: 13)
private let todoItemTitleLineHeight: CGFloat = 18
private let todoItemMaxVisibleLines = 5

struct TodoItemRow<MenuContent: View>: View {

    let item: TodoItem
    let group: TodoGroup
    let needsAttention: Bool
    let isSelected: Bool
    let mergedItemTitles: [String]?
    let onCircleClick: () -> Void
    let onClick: () -> Void
    let menuItems: () -> MenuContent

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(" ").font(todoItemTitleFont).hidden()
                .overlay(statusCircle)
            VStack(alignment: .leading, spacing: 2) {
                ScrollView {
                    Text(item.title)
                        .font(todoItemTitleFont)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: todoItemTitleLineHeight * CGFloat(todoItemMaxVisibleLines))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if group == .pending {
                ProgressView()
                    .controlSize(.small)
            }
            if needsAttention {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundFill)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onClick() }
        .contextMenu { menuItems() }
    }

    private var backgroundFill: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.15))
        } else if isHovered {
            return AnyShapeStyle(Color.primary.opacity(0.08))
        } else {
            return AnyShapeStyle(Color.clear)
        }
    }

    // MARK: - Status Circle

    @ViewBuilder
    private var statusCircle: some View {
        let isFilled = group == .completed || group == .archived || group == .deleted
        let isClickable = group == .inProgress

        ZStack {
            if isFilled {
                Circle()
                    .fill(group.themeColor)
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .strokeBorder(group.themeColor, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .onTapGesture {
            if isClickable { onCircleClick() }
        }
        .onHover { hovering in
            if isClickable {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Subtitle

    private var subtitle: String {
        var parts: [String] = []
        if let branch = item.worktreeBranch {
            parts.append(branch)
        }
        parts.append(Self.relativeTimeString(from: item.updatedAt))
        if item.type == .merge, let titles = mergedItemTitles, !titles.isEmpty {
            parts.append(String(localized: "Contains: \(titles.joined(separator: ", "))"))
        }
        return parts.joined(separator: " · ")
    }

    private static func relativeTimeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "Just now") }
        if interval < 3600 { return String(localized: "\(Int(interval / 60)) min ago") }
        if interval < 86400 { return String(localized: "\(Int(interval / 3600))h ago") }
        return String(localized: "\(Int(interval / 86400))d ago")
    }
}
