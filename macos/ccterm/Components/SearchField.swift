import SwiftUI

struct SearchField: View {

    @Binding var text: String
    var placeholder: String = "Search…"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .padding(.leading, 4)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
    }
}
