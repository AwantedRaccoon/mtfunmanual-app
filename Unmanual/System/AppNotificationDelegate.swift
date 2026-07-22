@preconcurrency import UserNotifications
import UIKit

extension Notification.Name {
    static let unmanualOpenToday = Notification.Name("unmanual.openToday")
    static let unmanualLocalDataChanged = Notification.Name("unmanual.localDataChanged")
    static let unmanualReminderInputsChanged = Notification.Name(
        "unmanual.reminderInputsChanged"
    )
}

@MainActor
final class AppNotificationDelegate: NSObject, UIApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.identifier.hasPrefix(LocalReminderPlanner.requestPrefix) else {
            completionHandler([.banner, .list])
            return
        }
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier.hasPrefix(LocalReminderPlanner.requestPrefix) {
            NotificationCenter.default.post(name: .unmanualOpenToday, object: nil)
        }
        completionHandler()
    }
}
