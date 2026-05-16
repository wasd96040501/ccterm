import SwiftUI

/// Persistent "find in transcript" field. Mounted as a
/// `ToolbarItem(placement: .primaryAction)` on `ChatHistoryView`, so it
/// sits at the trailing edge of the window toolbar and never appears /
/// disappears — there is no open/close cycle.
///
/// Reads `Transcript2Controller.searchState` for the counter and to
/// enable / disable nav buttons; writes through `controller.runSearch(_:)`
/// on every keystroke (small transcripts re-scan in O(rows·blockLen);
/// large transcripts may later want a 100ms throttle here).
///
/// `TranscriptSearchBus.focusRequestCounter` is observed so the global
/// ⌘F Find command can hand focus to this field even when another
/// control had it.
struct ChatSearchBarView: View {
    @Bindable var controller: Transcript2Controller
    let searchBus: TranscriptSearchBus

    @State private var query: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField(
                String(localized: "Find in transcript"),
                text: $query
            )
            .textFieldStyle(.plain)
            .focused($isFocused)
            .frame(minWidth: 140, idealWidth: 180, maxWidth: 220)
            .testIdentifier("ChatSearchBar.Field")
            .onSubmit { controller.nextSearchHit() }
            .onChange(of: query) { _, new in
                controller.runSearch(new)
            }

            counterLabel

            Button(action: { controller.previousSearchHit() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(controller.searchState.totalHits == 0)
            .keyboardShortcut(.return, modifiers: [.shift])
            .testIdentifier("ChatSearchBar.PrevButton")
            .help(String(localized: "Previous match"))

            Button(action: { controller.nextSearchHit() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(controller.searchState.totalHits == 0)
            .testIdentifier("ChatSearchBar.NextButton")
            .help(String(localized: "Next match"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
        .testIdentifier("ChatSearchBar")
        .onChange(of: searchBus.focusRequestCounter) { _, _ in
            isFocused = true
        }
    }

    @ViewBuilder
    private var counterLabel: some View {
        if !query.isEmpty {
            let total = controller.searchState.totalHits
            let current = total > 0 ? (controller.searchState.currentIndex ?? -1) + 1 : 0
            Text("\(current) / \(total)")
                .monospacedDigit()
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .testIdentifier("ChatSearchBar.Counter")
        }
    }
}
