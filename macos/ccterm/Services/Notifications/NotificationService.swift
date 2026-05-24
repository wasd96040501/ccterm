import AppKit
import Observation
import UserNotifications

/// Routes `TurnEndedNotice`s into the system Notification Center, and
/// surfaces user clicks back to the UI as `pendingActivationSessionId`.
///
/// Lifetime: one instance, owned by `AppState`, lives for the whole app
/// session. `bootstrap()` requests permission + installs the
/// `UNUserNotificationCenter` delegate exactly once at launch.
///
/// Gating: drops silently when the app is the frontmost application —
/// the user already sees the transcript update, a banner on top of it
/// is just noise. The "window not in focus" rule from the product spec
/// maps cleanly onto `NSApp.isActive` here because the app is single-
/// window.
@Observable
@MainActor
final class NotificationService: NSObject {

    /// Hard cap on the notification body so a long assistant reply
    /// can't blow out the notification banner. macOS' banner shows at
    /// most a few lines anyway; cutting on our side keeps the data we
    /// hand to the OS bounded and avoids odd mid-line ellipsis from
    /// the system layout engine.
    private static let bodyMaxChars = 240

    @ObservationIgnored private let activation: AppActivationTracker
    @ObservationIgnored private var didBootstrap = false

    /// Most recent click target. `ChatSessionViewController`
    /// observes this, flips `MainSelectionModel.selection` to
    /// `.session(sid)`, then calls `clearPendingActivation()` so a
    /// re-click on the same session still fires.
    private(set) var pendingActivationSessionId: String?

    /// Authorization status snapshot — `nil` until the first query
    /// resolves. Settings UI can read this if we ever want to nudge the
    /// user toward System Settings after a deny.
    private(set) var authorizationStatus: UNAuthorizationStatus?

    init(activation: AppActivationTracker) {
        self.activation = activation
        super.init()
    }

    nonisolated deinit {}

    /// Install the delegate + request permission. Idempotent (safe to
    /// call once per launch). First launch shows the system prompt;
    /// subsequent launches are no-ops because the OS remembers the
    /// choice.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                let settings = await center.notificationSettings()
                self.authorizationStatus = settings.authorizationStatus
                appLog(
                    .info, "NotificationService",
                    "auth granted=\(granted) status=\(settings.authorizationStatus.rawValue)")
            } catch {
                appLog(
                    .warning, "NotificationService",
                    "requestAuthorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Entry point from `SessionManager.onTurnEndedNotice`. Drops if the
    /// app is already active.
    func handleTurnEnded(_ notice: TurnEndedNotice) {
        guard !activation.isAppActive else { return }
        post(notice: notice)
    }

    /// Called by RootView2 after it consumes the activation request.
    func clearPendingActivation() {
        pendingActivationSessionId = nil
    }

    private func post(notice: TurnEndedNotice) {
        let content = UNMutableNotificationContent()
        content.title = Self.flattened(notice.title)
        content.body = Self.truncated(Self.flattened(notice.body))
        content.sound = .default
        content.userInfo = ["sessionId": notice.sessionId]
        let request = UNNotificationRequest(
            identifier: "ccterm.turnEnded.\(notice.sessionId).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                appLog(
                    .warning, "NotificationService",
                    "post failed: \(error.localizedDescription)")
            }
        }
    }

    private static func truncated(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > bodyMaxChars else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: bodyMaxChars)
        return trimmed[..<cut] + "\u{2026}"
    }

    /// Collapse all runs of whitespace (newlines, tabs, multi-space) into a
    /// single space and trim the ends. macOS' notification banner is tiny —
    /// internal newlines waste vertical room without adding meaning once the
    /// body is already truncated to a few hundred chars.
    private static func flattened(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Used from the nonisolated delegate callback to hop back onto
    /// the main actor for the activation-state write.
    fileprivate func activateForSession(_ sessionId: String) {
        NSApp.activate(ignoringOtherApps: true)
        pendingActivationSessionId = sessionId
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {

    /// macOS calls this if a notification arrives while we *are* the
    /// frontmost app. Our gating in `handleTurnEnded` normally prevents
    /// posts in that state; if the user re-activated between post and
    /// delivery, present the banner anyway — the message is still useful.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// User clicked the notification banner / dock badge.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let sid = userInfo["sessionId"] as? String else { return }
        await MainActor.run { [weak self] in
            self?.activateForSession(sid)
        }
    }
}
