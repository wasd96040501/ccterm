import SwiftUI

struct LogWindowView: View {
    @State private var viewModel = LogWindowViewModel()
    @State private var autoScroll = true
    @State private var exportCopied = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logList
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            SearchField(text: $viewModel.searchText, placeholder: String(localized: "Filter"))
                .frame(width: 200)

            Spacer()

            levelFilterButtons

            categoryPicker

            Button {
                let text = viewModel.filteredEntries.map { entry in
                    let time = Self.exportTimeFormatter.string(from: entry.timestamp)
                    return "\(time) [\(entry.level.label)] [\(entry.category)] \(entry.message)"
                }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                exportCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    exportCopied = false
                }
            } label: {
                ZStack {
                    Image(systemName: "doc.on.doc")
                        .opacity(exportCopied ? 0 : 1)
                    Image(systemName: "checkmark")
                        .opacity(exportCopied ? 1 : 0)
                        .foregroundStyle(.green)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(HoverCapsuleStyle())
            .help(String(localized: "Copy All"))

            Button {
                viewModel.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(HoverCapsuleStyle())
            .help(String(localized: "Clear Logs"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var levelFilterButtons: some View {
        HStack(spacing: 4) {
            ForEach(LogLevel.allCases, id: \.rawValue) { level in
                Button {
                    if viewModel.selectedLevel == level {
                        viewModel.selectedLevel = nil
                    } else {
                        viewModel.selectedLevel = level
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: level.icon)
                        Text(level.label)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(HoverCapsuleStyle(
                    staticFill: viewModel.selectedLevel == level
                        ? Color.accentColor.opacity(0.2)
                        : nil
                ))
            }
        }
    }

    private var categoryPicker: some View {
        Menu {
            Button(String(localized: "All Categories")) {
                viewModel.selectedCategory = nil
            }
            if !viewModel.availableCategories.isEmpty {
                Divider()
                ForEach(viewModel.availableCategories, id: \.self) { category in
                    Button(category) {
                        viewModel.selectedCategory = category
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(viewModel.selectedCategory ?? String(localized: "All"))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private static let exportTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(viewModel.filteredEntries.enumerated()),
                        id: \.element.id
                    ) { index, entry in
                        LogRowView(entry: entry, isEvenRow: index % 2 == 0)
                            .id(entry.id)
                    }
                }
            }
            .onChange(of: viewModel.filteredEntries.last?.id) { _, newId in
                if let newId, autoScroll {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newId, anchor: .bottom)
                    }
                }
            }
        }
    }
}
