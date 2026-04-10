import SwiftUI

/// Permission card container with page dots for multiple cards.
struct PermissionOverlayView: View {
    @Bindable var viewModel: PermissionViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Fixed-height top row: page dots when multiple cards, empty spacer otherwise.
            ZStack {
                if viewModel.cards.count > 1 {
                    PageDotIndicatorSwiftUIView(count: viewModel.cards.count, currentIndex: $viewModel.currentIndex)
                }
            }
            .frame(height: 16)
            .padding(.top, 2)

            if let card = viewModel.currentCard {
                cardView(for: card)
                    .id(card.id)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: viewModel.currentIndex)
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
