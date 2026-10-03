import Foundation

/// A live session's state, as the sidebar and a tab draw it.
public enum SidebarActivity: Equatable {
    /// Running, no turn.
    case idle
    /// A turn running: the turning arc.
    case responding
    /// A request waits for the reader.
    case needsInput
    /// The CLI exited without being asked to.
    case failed(message: String)

    /// How urgently the reader's eye is wanted: a request to answer first,
    /// then a failure, then work in flight, then a session merely open.
    private var urgency: Int {
        switch self {
        case .needsInput: 3
        case .failed: 2
        case .responding: 1
        case .idle: 0
        }
    }

    /// The most urgent of `activities`, `nil` when there are none.
    public static func mostUrgent(of activities: some Sequence<SidebarActivity>) -> SidebarActivity? {
        activities.max { $0.urgency < $1.urgency }
    }
}

extension SidebarNode {
    /// The most urgent activity of this node's own session and of every
    /// session under it, `nil` when none is live.
    public func mostUrgentActivity(in activities: [URL: SidebarActivity]) -> SidebarActivity? {
        var found: [SidebarActivity] = []
        func visit(_ node: SidebarNode) {
            if let url = node.transcriptURL, let activity = activities[url] { found.append(activity) }
            node.children.forEach(visit)
        }
        visit(self)
        return .mostUrgent(of: found)
    }
}
