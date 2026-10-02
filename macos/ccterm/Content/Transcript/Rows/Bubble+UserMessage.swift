import Foundation
import TranscriptKit

extension Bubble {
    /// What TranscriptKit draws: the words, with the runs it sets apart. A
    /// picture token is a link to `imageURL`, so hovering and clicking it reach
    /// the transcript's delegate like any link.
    var userMessage: TranscriptRowContent.UserMessage {
        TranscriptRowContent.UserMessage(
            text,
            tokens: tokens.map { token in
                switch token.kind {
                case .command:
                    TranscriptRowContent.UserMessage.Token(
                        range: token.range, kind: .command, toolTip: token.toolTip)
                case .image(let number):
                    TranscriptRowContent.UserMessage.Token(
                        range: token.range, kind: .link(Self.imageURL(number)), toolTip: token.toolTip)
                }
            }, isPending: isPending, isMonospaced: isMonospaced)
    }

    /// What a picture token links to.
    nonisolated static func imageURL(_ number: Int) -> URL { URL(string: "\(imageScheme):\(number)")! }

    /// The picture number a token's link names; `nil` for any other URL.
    nonisolated static func imageNumber(of url: URL) -> Int? {
        guard url.scheme == imageScheme else { return nil }
        return Int(url.absoluteString.dropFirst(imageScheme.count + 1))
    }

    private nonisolated static let imageScheme = "ccterm-image"
}
