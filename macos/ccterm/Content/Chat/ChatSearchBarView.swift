import SwiftUI

/// Floating "find in transcript" bar. Toggled by ⌘F from
/// `ChatHistoryView`; dismissed via the close button or ESC.
///
/// Reads `Transcript2Controller.searchState` to render the counter and
/// enable / disable nav buttons; writes the query through
/// `controller.runSearch(_:)` on every keystroke. Re-running the same
/// query is idempotent on the coordinator side, so debouncing here
/// isn't necessary for the 80% case (small transcripts) — large
/// transcripts may want a 100ms throttle later, but ship the simple
/// version first.
struct ChatSearchBarView: View {
    @Bindable var controller: Transcript2Controller
    /// Called when the user dismisses (close button / ESC / ⌘F again).
    /// Owner is expected to flip its own `isSearchVisible` state and
    /// rely on `.onDisappear` here to clear the search session.
    var onDismiss: () -> Void

    @State private var query: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField(
                String(localized: "Find in transcript"),
                text: $query
            )
            .textFieldStyle(.plain)
            .focused($isFocused)
            .testIdentifier("ChatSearchBar.Field")
            .onSubmit { controller.nextSearchHit() }
            .onChange(of: query) { _, new in
                controller.runSearch(new)
            }

            counterLabel

            Button(action: { controller.previousSearchHit() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(controller.searchState.totalHits == 0)
            .keyboardShortcut(.return, modifiers: [.shift])
            .testIdentifier("ChatSearchBar.PrevButton")
            .help(String(localized: "Previous match"))

            Button(action: { controller.nextSearchHit() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(controller.searchState.totalHits == 0)
            .testIdentifier("ChatSearchBar.NextButton")
            .help(String(localized: "Next match"))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .testIdentifier("ChatSearchBar.CloseButton")
            .help(String(localized: "Close find bar"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .frame(width: 320)
        .testIdentifier("ChatSearchBar")
        .onAppear { isFocused = true }
        .onDisappear { controller.endSearch() }
    }

    @ViewBuilder
    private var counterLabel: some View {
        if !query.isEmpty {
            let total = controller.searchState.totalHits
            let current = total > 0 ? (controller.searchState.currentIndex ?? -1) + 1 : 0
            Text("\(current) / \(total)")
                .monospacedDigit()
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .testIdentifier("ChatSearchBar.Counter")
        }
    }
}
