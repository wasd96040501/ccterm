import SwiftUI

/// Plan 评论模式的输入区域：引用选区列表 + 评论输入框。
struct PlanCommentInputView: View {
    @Bindable var viewModel: PlanReviewViewModel

    private let topPadding: CGFloat = 12
    private let contentPadding: CGFloat = 20
    private let quoteMaxHeight: CGFloat = 130

    @State private var quoteContentHeight: CGFloat = 0
    @State private var isInputFocused: Bool = false
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    private var sendKeyBehavior: SendKeyBehavior {
        SendKeyBehavior(rawValue: sendKeyBehaviorRaw) ?? .commandEnter
    }

    var body: some View {
        VStack(spacing: 0) {
            // Selection quote bars (supports multiple quotes)
            if !viewModel.pendingCommentSelections.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    quoteList
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            guard height != quoteContentHeight else { return }
                            DispatchQueue.main.async {
                                withAnimation(.smooth(duration: 0.35)) {
                                    quoteContentHeight = height
                                }
                            }
                        }
                }
                .frame(height: min(quoteContentHeight, quoteMaxHeight))
                Divider()
            }

            // Comment text area
            TextInputView(
                text: $viewModel.commentText,
                isEnabled: true,
                placeholder: sendKeyBehavior.commentPlaceholder,
                font: .systemFont(ofSize: 14),
                minLines: 2,
                maxLines: 10,
                onTextChanged: nil,
                onCommandReturn: nil,
                onEscape: nil,
                keyInterceptor: nil,
                isFocused: $isInputFocused,
                desiredCursorPosition: .constant(nil),
                sendKeyBehavior: sendKeyBehavior
            )
            .padding(.top, topPadding)
            .padding(.horizontal, contentPadding - 7)

            Spacer().frame(height: 42)
        }
    }

    // MARK: - Quote List

    private var quoteList: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.pendingCommentSelections.enumerated()), id: \.element.id) { index, selection in
                HStack(spacing: 0) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .padding(.leading, 13)
                    Text(selection.selectedText.trimmedForQuote)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, 6)
                        .padding(.vertical, 4)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.pendingCommentSelections.removeAll { $0.id == selection.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 8)
                }
                .background(index % 2 == 1 ? Color(nsColor: .controlAlternatingRowBackgroundColors[1]) : Color.clear)
            }
        }
    }
}
