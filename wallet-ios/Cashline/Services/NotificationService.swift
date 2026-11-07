import Foundation
import UserNotifications
import CashlineCore

/// Schedules bill reminders as local notifications, so they fire even when
/// the app is closed.
actor NotificationService {
    private let prefix = "cashline."

    /// Asks for permission. Returns whether notifications are allowed.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Replaces every pending Cashline reminder with a fresh plan.
    func reschedule(_ state: AppState, today: Day) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        guard state.settings.notificationsEnabled, await isAuthorized() else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        for r in ReminderPlanner.plan(state, today: today, currentHour: hour) {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.threadIdentifier = "bills"
            let when = DateComponents(year: r.day.year, month: r.day.month, day: r.day.day, hour: r.hour)
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + r.id, content: content, trigger: trigger))
        }
    }

    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
