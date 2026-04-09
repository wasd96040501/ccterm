import SwiftUI

// MARK: - Action Descriptor

struct PermissionActionBarAction {
    let title: String
    let isPrimary: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(
        title: String, isPrimary: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void
    ) {
        self.title = title
        self.isPrimary = isPrimary
        self.isEnabled = isEnabled
        self.action = action
    }
}

// MARK: - PermissionActionBar

/// Capsule button bar for permission cards.
///
/// Layout: `(Deny) (▶)  ···  (Action1) (Primary Action)`
///
/// - **Deny**: immediate deny (interrupt), light orange background.
/// - **▶**: toggles a feedback text input below. Enter submits deny-with-reason.
///
struct PermissionActionBar: View {
    let actions: [PermissionActionBarAction]
    /// Called with `nil` for immediate deny, or a feedback string for deny-with-reason.
    let onDeny: (String?) -> Void

    private let cardPadding: CGFloat = 14
    private let denyFill = Color.orange.opacity(0.12)

    @State private var isDenyExpanded = false
    @State private var feedbackText = ""
    @State private var isFocused = false
    @State private var cursorPosition: Int? = nil

    var body: some View {
        VStack(spacing: 8) {
            buttonRow
            feedbackInput
        }
        .padding(.bottom, cardPadding)
    }

    // MARK: - Button Row

    private var buttonRow: some View {
        HStack(spacing: 2) {
            denyButton
            expandButton
            Spacer()
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                actionCapsule(action)
            }
        }
        .padding(.horizontal, cardPadding)
    }

    /// Immediate deny (interrupt).
    /// Uses `.plain` + `.hoverCapsule` for native press dimming (same as directory button).
    private var denyButton: some View {
        Button {
            onDeny(nil)
        } label: {
            Text("Deny")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .hoverCapsule(staticFill: denyFill)
    }

    /// Toggle feedback input for deny-with-reason.
    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isDenyExpanded.toggle()
            }
            if isDenyExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.orange)
                .rotationEffect(.degrees(isDenyExpanded ? 90 : 0))
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionCapsule(_ action: PermissionActionBarAction) -> some View {
        Button {
            action.action()
        } label: {
            Text(action.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(action.isPrimary ? .white : .primary)
        }
        .buttonStyle(.plain)
        .hoverCapsule(staticFill: action.isPrimary ? .accentColor : nil)
        .opacity(action.isEnabled ? 1.0 : 0.4)
        .disabled(!action.isEnabled)
    }

    // MARK: - Feedback Input

    @ViewBuilder
    private var feedbackInput: some View {
        if isDenyExpanded {
            SwiftUITextInputView(
                text: $feedbackText,
                placeholder: String(localized: "⌘Enter to deny with feedback"),
                font: .systemFont(ofSize: 12),
                minLines: 1,
                maxLines: 3,
                onCommandReturn: { submitDeny() },
                onEscape: { collapseDeny() },
                isFocused: $isFocused,
                desiredCursorPosition: $cursorPosition
            )
            .padding(.horizontal, cardPadding)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Actions

    private func submitDeny() {
        let text = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        onDeny(text.isEmpty ? nil : text)
    }

    private func collapseDeny() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isDenyExpanded = false
        }
    }
}
