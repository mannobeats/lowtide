import Foundation
import UserNotifications

/// macOS notifications: asks permission the first time, posts each body as
/// its own notification. Nothing outside an app bundle (tests, `swift run`).
public enum Notify {
    public static func post(_ title: String, _ bodies: [String], sound: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil, !bodies.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for body in bodies {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                if sound { content.sound = .default }
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }
}
