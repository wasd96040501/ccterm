import SwiftUI

struct SwiftUIAskUserQuestionCardView: View {
    @Bindable var viewModel: AskUserQuestionCardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Questions content
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude has questions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if viewModel.questions.isEmpty {
                    Text("Claude asked a question, but no options were provided.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.questions) { question in
                                questionSection(question)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .scrollIndicators(.automatic)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Action bar
            PermissionActionBar(
                actions: [
                    .init(title: "Confirm", isPrimary: true, isEnabled: viewModel.allAnswered) {
                        viewModel.confirm()
                    },
                ],
                onDeny: { _ in viewModel.deny() }
            )
        }
    }

    @ViewBuilder
    private func questionSection(_ question: AskUserQuestionCardViewModel.ParsedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(question.question)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            radioGroup(for: question)
        }
    }

    @ViewBuilder
    private func radioGroup(for question: AskUserQuestionCardViewModel.ParsedQuestion) -> some View {
        let qIndex = question.id
        let options: [RadioOption] = {
            var opts = question.options.map { opt in
                RadioOption(
                    id: opt.id,
                    title: opt.label,
                    description: opt.description
                )
            }
            opts.append(.init(id: question.options.count, title: "Other"))
            return opts
        }()

        let selectedBinding = Binding<Int>(
            get: { viewModel.answers[qIndex].selectedIndex ?? -1 },
            set: { viewModel.answers[qIndex].selectedIndex = $0 }
        )

        RadioGroupView(
            options: options,
            selectedIndex: selectedBinding
        ) { index in
            if index == question.options.count {
                AnyView(
                    TextField("Type something", text: Binding(
                        get: { viewModel.answers[qIndex].otherText },
                        set: { viewModel.answers[qIndex].otherText = $0 }
                    ))
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 200)
                    .opacity(viewModel.answers[qIndex].selectedIndex == question.options.count ? 1.0 : 0.4)
                    .disabled(viewModel.answers[qIndex].selectedIndex != question.options.count)
                )
            } else {
                AnyView(EmptyView())
            }
        }
    }
}
