import SwiftUI

/// Permission card container with page dots for multiple cards.
struct SwiftUIPermissionOverlayView: View {
    let cards: [PermissionCardItem]
    @Binding var currentIndex: Int

    var body: some View {
        VStack(spacing: 0) {
            // Fixed-height top row: page dots when multiple cards, empty spacer otherwise.
            ZStack {
                if cards.count > 1 {
                    PageDotIndicatorSwiftUIView(count: cards.count, currentIndex: $currentIndex)
                }
            }
            .frame(height: 16)
            .padding(.top, 2)

            if let card = cards[safe: currentIndex] {
                cardView(for: card)
                    .id(card.id)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: currentIndex)
    }

    @ViewBuilder
    private func cardView(for card: PermissionCardItem) -> some View {
        switch card.cardType {
        case .standard(let vm): StandardCardView(viewModel: vm)
        case .exitPlanMode(let vm): ExitPlanModeCardView(viewModel: vm)
        case .askUserQuestion(let vm): SwiftUIAskUserQuestionCardView(viewModel: vm)
        }
    }
}
