import AppKit
import Observation

/// App-scope registry of external applications that can open a session's
/// working directory ("Open in …" in the sidebar context menu).
///
/// Two sources, merged into one ordered `targets` list:
/// - **Built-ins** (Finder, Terminal) — always shown. They resolve via
///   LaunchServices like everything else, but ship with every macOS so
///   they're effectively guaranteed.
/// - **Optional whitelist** (editors / terminals) — included only when
///   the app is actually installed.
///
/// Resolution is a handful of `NSWorkspace.urlForApplication` lookups;
/// it runs once asynchronously off the main actor at launch (`refresh()`)
/// and writes `targets` back on the main actor. Display names come from
/// each bundle's localized name (`FileManager.displayName`) so "Finder"
/// shows as "访达" / "Terminal" as "终端" on a localized system without
/// us hardcoding translations.
@Observable
@MainActor
final class OpenInAppService {

    /// One resolved, openable application.
    struct Target: Identifiable, Sendable {
        /// Bundle identifier — stable id for the row.
        let id: String
        /// User-visible (localized) application name.
        let name: String
        /// Resolved application bundle URL, used to launch it.
        let url: URL
        /// Cached 16pt menu icon.
        let icon: NSImage
    }

    /// Merged, ordered list of installed targets. Empty until the first
    /// `refresh()` completes (a few hundred microseconds after launch).
    private(set) var targets: [Target] = []

    /// Always-shown built-ins, in display order.
    private static let builtins: [KnownApp] = [
        KnownApp(bundleId: "com.apple.finder", fallbackName: "Finder"),
        KnownApp(bundleId: "com.apple.Terminal", fallbackName: "Terminal"),
    ]

    /// Optional whitelist — shown only when installed, in display order.
    private static let whitelist: [KnownApp] = [
        KnownApp(bundleId: "com.microsoft.VSCode", fallbackName: "Visual Studio Code"),
        KnownApp(bundleId: "dev.zed.Zed", fallbackName: "Zed"),
        KnownApp(bundleId: "com.apple.dt.Xcode", fallbackName: "Xcode"),
        KnownApp(bundleId: "com.mitchellh.ghostty", fallbackName: "Ghostty"),
    ]

    private struct KnownApp: Sendable {
        let bundleId: String
        let fallbackName: String
    }

    /// A bundle id + its resolved URL, carried back from the off-main
    /// probe so the main actor only does icon/name finalization.
    private struct ResolvedApp: Sendable {
        let bundleId: String
        let fallbackName: String
        let url: URL
    }

    init() {}

    /// Probe the whitelist off-main, then publish `targets` on the main
    /// actor. Idempotent — safe to call again to re-scan (e.g. after an
    /// app is installed); the latest scan wins.
    func refresh() {
        Task { [weak self] in
            let resolved = await Self.probeInstalled()
            guard let self else { return }
            self.targets = resolved.map { app in
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                icon.size = NSSize(width: 16, height: 16)
                let display = FileManager.default.displayName(atPath: app.url.path)
                return Target(
                    id: app.bundleId,
                    name: display.isEmpty ? app.fallbackName : display,
                    url: app.url,
                    icon: icon)
            }
        }
    }

    /// Open `path` (a directory) with the given target application. For
    /// editors this opens the folder as a workspace; for terminals it
    /// opens a session rooted at the folder; for Finder it opens a
    /// window showing the folder.
    func open(path: String, with target: Target) {
        let dir = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([dir], withApplicationAt: target.url, configuration: config) {
            _, error in
            if let error {
                appLog(
                    .error, "OpenInAppService",
                    "open \(target.id) at \(path) failed: \(error.localizedDescription)")
            }
        }
    }

    /// LaunchServices lookups, off the main actor. Built-ins first, then
    /// installed whitelist apps; order within each group is preserved.
    private static func probeInstalled() async -> [ResolvedApp] {
        await Task.detached(priority: .utility) {
            (builtins + whitelist).compactMap { app -> ResolvedApp? in
                guard
                    let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: app.bundleId)
                else { return nil }
                return ResolvedApp(bundleId: app.bundleId, fallbackName: app.fallbackName, url: url)
            }
        }.value
    }
}
