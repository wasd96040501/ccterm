import SwiftUI

struct BranchPickerView: View {

    let branches: [String]
    let currentBranch: String?
    let onSelect: (String) -> Void

    @State private var searchText = ""
    @State private var selected: String?

    private var filteredBranches: [String] {
        if searchText.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            searchSection
            Divider()
            branchListSection
            Divider()
            bottomBar
        }
        .frame(width: 300)
        .onAppear { selected = currentBranch }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Switch Branch")
                .font(.headline)
            Text("Select the target branch to switch to")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Search

    private var searchSection: some View {
        SearchField(text: $searchText, placeholder: String(localized: "Search branches…"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    // MARK: - Branch List

    private var branchListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "Branches (\(branches.count))"))

            if filteredBranches.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredBranches, id: \.self) { branch in
                            BranchRow(
                                branch: branch,
                                isCurrent: branch == currentBranch,
                                isSelected: branch == selected,
                                onTap: { selected = branch },
                                onDoubleTap: {
                                    selected = branch
                                    onSelect(branch)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(height: 156, alignment: .top)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Confirm") {
                if let selected { onSelect(selected) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selected == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No Matching Branches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - BranchRow

private struct BranchRow: View {

    let branch: String
    let isCurrent: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(branch)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
                if isCurrent {
                    Text("current")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleTap))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview("BranchPickerView") {
    struct PreviewWrapper: View {
        @State private var showPopover = false

        var body: some View {
            Button("Select Branch") {
                print("[debug] button tapped, showPopover=\(showPopover)")
                showPopover = true
            }
            .popover(isPresented: $showPopover) {
                BranchPickerView(
                    branches: [
                        "main",
                        "develop",
                        "feature/auth-login",
                        "feature/settings-page",
                        "fix/memory-leak",
                        "release/v2.0",
                    ],
                    currentBranch: "main",
                    onSelect: { branch in
                        print("[debug] onSelect: \(branch)")
                        showPopover = false
                    }
                )
            }
            .onChange(of: showPopover) { _, newValue in
                print("[debug] showPopover changed to \(newValue)")
            }
            .frame(width: 300, height: 200)
        }
    }
    return PreviewWrapper()
}
