@preconcurrency import UserNotifications
import Foundation

actor UserNotificationClient: LocalNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        let settings = await center.notificationSettings()
        let authorization: LocalNotificationAuthorization = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .denied
        }
        return LocalNotificationSettingsSnapshot(
            authorization: authorization,
            alertsEnabled: settings.alertSetting == .enabled
        )
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func pendingRequests() async -> [LocalPendingNotificationRequest] {
        await center.pendingNotificationRequests().map {
            LocalPendingNotificationRequest(
                identifier: $0.identifier,
                fireAt: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            )
        }
    }

    func add(_ request: LocalReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.userInfo = request.userInfo
        content.sound = nil
        content.badge = nil

        guard let timeZone = TimeZone(identifier: request.timeZoneIdentifier) else {
            throw UserNotificationClientFailure.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: request.fireAt
        )
        components.timeZone = timeZone
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

private enum UserNotificationClientFailure: Error {
    case unknownTimeZone
}
