import SwiftUI

// MARK: - RadioOption

struct RadioOption: Identifiable {
    let id: Int
    let title: String
    let description: String?

    init(id: Int, title: String, description: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
    }
}

// MARK: - RadioGroupView

/// Unified radio button group component used by all permission card types.
/// Supports description text and accessory views (e.g., text fields) per option.
struct RadioGroupView<Accessory: View>: View {
    let options: [RadioOption]
    @Binding var selectedIndex: Int
    @ViewBuilder let accessory: (Int) -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options) { option in
                radioRow(option)
            }
        }
    }

    @ViewBuilder
    private func radioRow(_ option: RadioOption) -> some View {
        let isSelected = selectedIndex == option.id

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(option.title)
                    .font(.system(size: 12))
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedIndex = option.id }

            if let desc = option.description {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
                    .padding(.bottom, 2)
            }

            if isSelected {
                accessory(option.id)
                    .padding(.leading, 18)
            }
        }
    }
}

/// Convenience initializer when no accessory views are needed.
extension RadioGroupView where Accessory == EmptyView {
    init(options: [RadioOption], selectedIndex: Binding<Int>) {
        self.options = options
        self._selectedIndex = selectedIndex
        self.accessory = { _ in EmptyView() }
    }
}
