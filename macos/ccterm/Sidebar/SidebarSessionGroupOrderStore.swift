import Foundation

/// UserDefaults-backed source of truth for the sidebar's group (project
/// folder) ordering. The sidebar reads this on every records refresh;
/// drag-and-drop and "new project sent" both write to it.
///
/// Semantics:
/// - `storedOrder()` returns the raw persisted order. The pure ordering
///   logic — filtering it down to currently-present folders, then
///   appending the alphabetical remainder — lives in `SidebarTreeModel`
///   (its private `arrange`), which takes this snapshot as input rather
///   than reading UserDefaults itself.
/// - `prependIfAbsent(_:)` is called when the sidebar detects a newly-
///   appeared group between two records refreshes (i.e., the user just
///   created a session in a folder that had no prior sessions). The
///   name lands at the front of the stored order.
/// - `replace(with:)` overwrites the stored order. Called after a
///   drag-and-drop commits.
@MainActor
final class SidebarSessionGroupOrderStore {

    static let defaultsKey = "ccterm.sidebar.groupOrder.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SidebarSessionGroupOrderStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Returns the raw stored order. May contain names that are no
    /// longer present in the session repository (stale folders are kept
    /// so they retain their slot if sessions land in them again).
    func storedOrder() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Push `group` to the front of the stored order if it isn't there
    /// yet. No-op when already present (prevents drag → re-create
    /// promoting a folder back to the top by accident).
    func prependIfAbsent(_ group: String) {
        var current = storedOrder()
        guard !current.contains(group) else { return }
        current.insert(group, at: 0)
        defaults.set(current, forKey: key)
    }

    /// Replace the stored order in one shot. Called after a drag-and-
    /// drop commit with the new full list of folder names (in their new
    /// visual order).
    func replace(with order: [String]) {
        defaults.set(order, forKey: key)
    }
}
