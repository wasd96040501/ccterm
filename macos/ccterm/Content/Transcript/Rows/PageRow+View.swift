import AppKit
import TranscriptKit

/// Where a page row meets TranscriptKit: which content it is, how tall a
/// `.view` row is, and which view draws it — the one switch from row kinds
/// to row views.
extension PageRow {
    var transcriptRow: TranscriptRow {
        TranscriptRow(id: id, content: content)
    }

    private var content: TranscriptRowContent {
        switch kind {
        case .prompt(let text): .userMessage(text)
        case .markdown(let markdown): .markdown(markdown)
        default: .view
        }
    }

    /// A `.view` row's height at `width`, from the model alone.
    @MainActor
    func height(width: CGFloat) -> CGFloat {
        switch kind {
        case .prompt, .markdown:
            preconditionFailure("TranscriptKit measures its own rows")
        case .runLine, .runItem, .newsLine, .newsItem, .agentReport:
            WorkLineRowView.height(for: workLine(isSelected: false, flashes: false), width: width)
        case .showMore(let runID, let hidden):
            ShowMoreRowView.height(for: .init(runID: runID, hidden: hidden), width: width)
        case .approval(let approval):
            ApprovalCardView.height(for: approval, width: width)
        case .command(let command):
            CapsuleRowView.height(for: command, width: width)
        case .divider(let divider):
            DividerRowView.height(for: divider, width: width)
        case .interruption:
            InterruptionRowView.height(for: (), width: width)
        case .caption(let caption):
            CaptionRowView.height(for: caption, width: width)
        case .question(let question):
            QuestionRowView.height(for: question, width: width)
        case .planDecision(let callID):
            PlanDecisionRowView.height(for: callID, width: width)
        }
    }

    /// A `.view` row's view, recycled through `transcript` and configured.
    /// Call from `transcriptView(_:viewForRow:)` only.
    @MainActor
    func makeView(
        in transcript: TranscriptView, isSelected: Bool, flashes: Bool, delegate: PageRowViewDelegate
    ) -> NSView {
        func view<V: PageRowView>(_: V.Type, _ model: V.Model) -> V {
            let view = transcript.makeView(withIdentifier: V.reuseIdentifier) { V() }
            view.delegate = delegate
            view.configure(with: model)
            return view
        }
        switch kind {
        case .prompt, .markdown:
            preconditionFailure("TranscriptKit draws its own rows")
        case .runLine, .runItem, .newsLine, .newsItem, .agentReport:
            return view(WorkLineRowView.self, workLine(isSelected: isSelected, flashes: flashes))
        case .showMore(let runID, let hidden):
            return view(ShowMoreRowView.self, .init(runID: runID, hidden: hidden))
        case .approval(let approval):
            return view(ApprovalCardView.self, approval)
        case .command(let command):
            return view(CapsuleRowView.self, command)
        case .divider(let divider):
            return view(DividerRowView.self, divider)
        case .interruption:
            return view(InterruptionRowView.self, ())
        case .caption(let caption):
            return view(CaptionRowView.self, caption)
        case .question(let question):
            return view(QuestionRowView.self, question)
        case .planDecision(let callID):
            return view(PlanDecisionRowView.self, callID)
        }
    }

    /// A line of work as `WorkLineRowView` draws it: a single run or single
    /// piece of news opens its one item, a longer one toggles.
    private func workLine(isSelected: Bool, flashes: Bool) -> WorkLineRowView.Model {
        switch kind {
        case .runLine(let run, let disclosure):
            WorkLineRowView.Model(
                line: run.line, level: .line,
                action: run.isSingle ? .open(run.items[0].id) : .toggle(run.id, expanded: disclosure != .collapsed),
                origin: nil, isSelected: isSelected, flashes: flashes)
        case .runItem(let item):
            WorkLineRowView.Model(
                line: item.line, level: .item, action: .open(item.id), origin: nil,
                isSelected: isSelected,
                flashes: flashes)
        case .newsLine(let news, let disclosure):
            WorkLineRowView.Model(
                line: news.line, level: .line,
                action: news.isSingle ? .open(news.news[0].id) : .toggle(news.id, expanded: disclosure != .collapsed),
                origin: news.isSingle ? news.news[0].origin : nil, isSelected: isSelected, flashes: flashes)
        case .newsItem(let news):
            WorkLineRowView.Model(
                line: news.line, level: .item, action: .open(news.id), origin: news.origin,
                isSelected: isSelected,
                flashes: flashes)
        case .agentReport(let message):
            WorkLineRowView.Model(
                line: message.line, level: .line, action: .open(message.id), origin: nil,
                isSelected: isSelected, flashes: flashes)
        default:
            preconditionFailure("\(kind) is not a line of work")
        }
    }
}
