@preconcurrency import UserNotifications
import UIKit

extension Notification.Name {
    static let unmanualOpenToday = Notification.Name("unmanual.openToday")
    static let unmanualLocalDataChanged = Notification.Name("unmanual.localDataChanged")
    static let unmanualReminderInputsChanged = Notification.Name(
        "unmanual.reminderInputsChanged"
    )
}

enum DeferredAppDestination: Equatable, Sendable {
    case today
}

@MainActor
final class DeferredAppNavigationQueue {
    static let shared = DeferredAppNavigationQueue()
    private(set) var pendingDestination: DeferredAppDestination?

    private init() {}

    func enqueue(_ destination: DeferredAppDestination) {
        pendingDestination = destination
    }

    func consume() -> DeferredAppDestination? {
        defer { pendingDestination = nil }
        return pendingDestination
    }
}

@MainActor
enum AppNotificationResponseRouter {
    @discardableResult
    static func route(identifier: String) -> Bool {
        guard LocalReminderPlanner.isOwnedIdentifier(identifier)
        else {
            return false
        }
        DeferredAppNavigationQueue.shared.enqueue(.today)
        NotificationCenter.default.post(
            name: .unmanualOpenToday,
            object: nil
        )
        return true
    }
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
        AppNotificationResponseRouter.route(
            identifier:
            response.notification.request.identifier
        )
        completionHandler()
    }
}
