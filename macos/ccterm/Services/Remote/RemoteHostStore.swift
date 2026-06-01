import Foundation
import Observation

/// User-defaults-backed list of configured remote SSH hosts (design
/// `remote-execution.md` §3b). The persistent counterpart to `RemoteHost`,
/// app-scope and injected via `.environment()`, mirroring `RecentProjectsStore`.
///
/// Rules:
///
/// - Entries are unique by `id` (the stable `remoteHostId`); `upsert(_:)`
///   replaces an existing host in place or appends a new one.
/// - Insertion order is preserved (the capsule strip renders them left-to-right
///   after `Local`).
/// - **Load is lazy.** `init` does no I/O; the first public-member read decodes
///   UserDefaults. Unlike `RecentProjectsStore` there is no `fileExists` pass —
///   a host is a connection descriptor, not a local path — so the deferred load
///   is purely to keep `AppState.init` allocation-cheap and consistent with the
///   sibling store.
@Observable
@MainActor
final class RemoteHostStore {

    private static let defaultsKey = "RemoteHosts.v1"

    // Backing storage; the public surface routes through `loadIfNeeded()`. Plain
    // stored property (no `@ObservationIgnored`) so SwiftUI views reading `hosts`
    // re-render when the deferred load populates it.
    private var _hosts: [RemoteHost] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// macOS 26 SDK workaround — see `RecentProjectsStore.deinit` / `Session.deinit`.
    /// The default `@MainActor` deinit traps in `swift_task_deinitOnExecutorImpl`;
    /// `nonisolated` skips that path.
    nonisolated deinit {}

    /// All configured hosts, in insertion order.
    var hosts: [RemoteHost] {
        loadIfNeeded()
        return _hosts
    }

    /// Look up a host by its stable id. nil = unknown / local.
    func host(id: String) -> RemoteHost? {
        loadIfNeeded()
        return _hosts.first { $0.id == id }
    }

    /// Insert a new host or replace an existing one with the same `id`,
    /// preserving its position. Persists immediately.
    func upsert(_ host: RemoteHost) {
        loadIfNeeded()
        if let idx = _hosts.firstIndex(where: { $0.id == host.id }) {
            _hosts[idx] = host
        } else {
            _hosts.append(host)
        }
        save()
    }

    /// Remove the host with `id`. No-op if absent.
    func remove(id: String) {
        loadIfNeeded()
        let next = _hosts.filter { $0.id != id }
        guard next.count != _hosts.count else { return }
        _hosts = next
        save()
    }

    private func loadIfNeeded() {
        if hasLoaded { return }
        hasLoaded = true
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data)
        else {
            _hosts = []
            return
        }
        _hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(_hosts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
