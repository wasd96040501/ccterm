import Cocoa
import UniformTypeIdentifiers

struct DirectoryCompletionItem: CompletionItem {
    let path: String
    let isRecent: Bool

    init(path: String, isRecent: Bool = false) {
        self.path = path
        self.isRecent = isRecent
    }

    var displayText: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var displayIcon: NSImage? {
        NSWorkspace.shared.icon(for: .folder)
    }

    var displayDetail: String? { nil }
}
