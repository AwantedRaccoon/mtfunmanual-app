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
        guard LocalReminderPlanner.isOwnedIdentifier(
            notification.request.identifier
        ) else {
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
        if LocalReminderPlanner.isOwnedIdentifier(
            response.notification.request.identifier
        ) {
            NotificationCenter.default.post(name: .unmanualOpenToday, object: nil)
        }
        completionHandler()
    }
}
