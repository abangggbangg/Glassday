import UIKit
import UserNotifications

/// Per-task alerts as local notifications.
///
/// The page owns the "what": it sends the next week's alerts as a full list
/// (`alerts` bridge message) whenever tasks change, and this replaces everything
/// Glassday has pending. Title is "Gym 18:00", body is the location (e.g. "Room 3.12").
/// No entitlement or provisioning change is needed for local notifications.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()
    private let center = UNUserNotificationCenter.current()
    private static let prefix = "gd."
    /// iOS keeps at most 64 pending requests per app; leave headroom.
    private static let maxPending = 60

    /// Set by the web model; a tap that launched the app before it existed is held until then.
    var onOpenDay: ((String) -> Void)? {
        didSet { if let day = pendingDay, let open = onOpenDay { pendingDay = nil; open(day) } }
    }
    private var pendingDay: String?

    /// Must be installed before launch finishes so a tap that launches the app is delivered.
    func install() { center.delegate = self }

    /// "granted", "denied" or "ask" (not decided yet).
    func status(_ done: @escaping (String) -> Void) {
        center.getNotificationSettings { settings in
            let s: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: s = "granted"
            case .notDetermined: s = "ask"
            default: s = "denied"
            }
            DispatchQueue.main.async { done(s) }
        }
    }

    /// Only called when the person turns an alert on (asks in context, never at launch).
    func requestAccess(_ done: @escaping (String) -> Void) {
        status { [weak self] s in
            guard s == "ask", let self else { return done(s) }
            self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in self.status(done) }
        }
    }

    /// Replace every pending Glassday alert with `items`
    /// ([{id, title, body, at (ms since 1970), day}]). Past or malformed items are skipped.
    func replace(with items: [[String: Any]]) {
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: ours)

            let now = Date()
            let requests: [UNNotificationRequest] = items.compactMap { item -> (Date, UNNotificationRequest)? in
                guard let id = item["id"] as? String, let title = item["title"] as? String,
                      let ms = item["at"] as? Double else { return nil }
                let at = Date(timeIntervalSince1970: ms / 1000)
                guard at > now.addingTimeInterval(5) else { return nil }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = item["body"] as? String ?? ""
                content.sound = .default
                content.threadIdentifier = "glassday"
                if let day = item["day"] as? String { content.userInfo = ["day": day] }
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                return (at, UNNotificationRequest(identifier: Self.prefix + id, content: content, trigger: trigger))
            }
            .sorted { $0.0 < $1.0 }
            .prefix(Self.maxPending)
            .map(\.1)
            requests.forEach { self.center.add($0) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even while Glassday is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    /// Tapping an alert opens its day.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let day = response.notification.request.content.userInfo["day"] as? String {
            DispatchQueue.main.async {
                if let open = self.onOpenDay { open(day) } else { self.pendingDay = day }
            }
        }
        done()
    }
}
