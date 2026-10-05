import DisplayModels
import Foundation

nonisolated extension DocumentHeader {
    /// The header of `document`, worded by the kind of document it is.
    init(_ document: Document) {
        switch document.content {
        case .command(let call):
            self = Self.command(call)
        case .shellCommand(let command):
            self = Self.shellCommand(command)
        case .change, .newFile, .read:
            self = Self.source(document.content, workingDirectory: document.workingDirectory)
        default:
            self = Self.markdown(document.content)
        }
    }
}
