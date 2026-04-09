import SwiftUI

/// Displays queued messages above the input area.
struct SwiftUIQueuedMessagesView: View {
    let messages: [String]
    var onDelete: ((Int) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                HStack(alignment: .top, spacing: 0) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .padding(.leading, 13)
                        .padding(.top, 4)
                    Text(message)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .padding(.leading, 6)
                        .padding(.vertical, 4)

                    Spacer(minLength: 4)

                    Button {
                        onDelete?(index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                }
                .background(index % 2 == 1 ? Color(nsColor: .controlAlternatingRowBackgroundColors[1]) : Color.clear)
            }
        }
    }
}

#Preview {
    SwiftUIQueuedMessagesView(
        messages: ["First queued message", "Second longer queued message that should wrap to multiple lines if needed", "Third message"],
        onDelete: { _ in }
    )
    .frame(width: 400)
}
