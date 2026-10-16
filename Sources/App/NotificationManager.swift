import Foundation
import UserNotifications

/// Posts native notifications when an agent needs attention or finishes.
///
/// `UNUserNotificationCenter` requires a bundled, identified app; when run as a
/// bare binary (`swift run`) there is no bundle id, so we no-op to avoid a
/// crash. Notifications work once launched as `AgentPet.app`.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    /// `userInfo` key carrying the session a notification is about, so a click
    /// can bring that session's terminal forward.
    nonisolated static let sessionIdKey = "agentpet.sessionId"

    private let clickHandler = ClickHandler()

    /// Routes notification clicks to the session's terminal. Call once at launch.
    func installClickHandler() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = clickHandler
    }

    /// UserDefaults key for the in-app "show notifications" toggle (independent
    /// of the macOS permission): users who granted permission can still mute.
    static let enabledKey = "agentpet.notificationsEnabled"

    /// `UNUserNotificationCenter` needs a real bundle id; false under `swift run`.
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private var available: Bool { isAvailable }

    /// Whether the user wants notifications shown (defaults to on).
    var userEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    func notify(title: String, body: String, sessionId: String? = nil) {
        guard available, userEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sessionId { content.userInfo = [Self.sessionIdKey: sessionId] }
        // Sound is handled by SoundSettings (configurable per event).
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private final class ClickHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo[NotificationManager.sessionIdKey] as? String
        if let id {
            Task { @MainActor in AppDaemon.shared.focusTerminal(sessionId: id) }
        }
        completionHandler()
    }
}
