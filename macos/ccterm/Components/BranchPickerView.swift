import SwiftUI

struct BranchPickerView: View {

    let branches: [String]
    let currentBranch: String?
    /// Optional remote default branch name (e.g. `"origin/main"`). When non-nil,
    /// the picker shows a "Remote Main" group above the current branch group.
    /// Callers that don't care about remotes pass `nil` (or omit the argument)
    /// and the section disappears entirely.
    var remoteMainBranch: String? = nil
    /// Short status summary rendered as a second line under the current
    /// branch row (e.g. `"3 changes · ↑2"`). Nil means clean enough to skip;
    /// the row collapses back to a single line and the selection circle
    /// stays vertically centered with the branch label.
    var currentBranchStatus: String? = nil
    let onSelect: (String) -> Void

    @State private var searchText = ""
    @State private var selected: String?

    private var filteredBranches: [String] {
        if searchText.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredCurrentBranch: String? {
        guard let currentBranch else { return nil }
        return filteredBranches.first { $0 == currentBranch }
    }

    private var filteredOtherBranches: [String] {
        filteredBranches.filter { $0 != currentBranch }
    }

    /// Remote main, but only when it matches the current search filter.
    private var filteredRemoteMain: String? {
        guard let remoteMainBranch else { return nil }
        if searchText.isEmpty { return remoteMainBranch }
        return remoteMainBranch.localizedCaseInsensitiveContains(searchText) ? remoteMainBranch : nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchSection
            branchListSection
            bottomBar
        }
        .frame(width: 300)
        .onAppear { selected = currentBranch }
    }

    // MARK: - Search

    private var searchSection: some View {
        SearchField(text: $searchText, placeholder: String(localized: "Search branches…"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    // MARK: - Branch List

    private var branchListSection: some View {
        Group {
            if filteredBranches.isEmpty && filteredRemoteMain == nil {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let remote = filteredRemoteMain {
                            sectionHeader(String(localized: "Remote Main"))
                            BranchRow(
                                branch: remote,
                                isCurrent: false,
                                isSelected: remote == selected,
                                subtitle: nil,
                                onTap: { selected = remote },
                                onDoubleTap: {
                                    selected = remote
                                    onSelect(remote)
                                }
                            )
                        }

                        if let current = filteredCurrentBranch {
                            sectionHeader(String(localized: "Current Branch"))
                            BranchRow(
                                branch: current,
                                isCurrent: true,
                                isSelected: current == selected,
                                subtitle: currentBranchStatus,
                                onTap: { selected = current },
                                onDoubleTap: {
                                    selected = current
                                    onSelect(current)
                                }
                            )
                        }

                        if !filteredOtherBranches.isEmpty {
                            sectionHeader(String(localized: "Branches (\(filteredOtherBranches.count))"))
                            ForEach(filteredOtherBranches, id: \.self) { branch in
                                BranchRow(
                                    branch: branch,
                                    isCurrent: false,
                                    isSelected: branch == selected,
                                    subtitle: nil,
                                    onTap: { selected = branch },
                                    onDoubleTap: {
                                        selected = branch
                                        onSelect(branch)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(height: 200, alignment: .top)
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
    /// Optional second line under the branch label. When present, the row
    /// grows vertically and the selection circle stays aligned with the
    /// branch text (top line), not the row's geometric center.
    let subtitle: String?
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    // Match the branch text's line box so the icon's vertical
                    // center sits on the branch baseline even when the row
                    // has a status subtitle underneath.
                    .frame(width: 12, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
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
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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
                appLog(.debug, "BranchPickerView", "button tapped, showPopover=\(showPopover)")
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
                    currentBranch: "feature/auth-login",
                    remoteMainBranch: "origin/main",
                    currentBranchStatus: "3 changes · ↑2 ↓1",
                    onSelect: { branch in
                        appLog(.debug, "BranchPickerView", "onSelect: \(branch)")
                        showPopover = false
                    }
                )
            }
            .onChange(of: showPopover) { _, newValue in
                appLog(.debug, "BranchPickerView", "showPopover changed to \(newValue)")
            }
            .frame(width: 300, height: 200)
        }
    }
    return PreviewWrapper()
}
