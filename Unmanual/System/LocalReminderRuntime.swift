import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LocalReminderRuntime {
    private(set) var isReconciling = false
    private(set) var lastErrorCode: String?
    private var needsAnotherReconciliation = false

    private let client: any LocalNotificationClient

    init(client: any LocalNotificationClient = UserNotificationClient()) {
        self.client = client
    }

    func reconcile(
        reader: AppReadActor,
        writer: AppDataWriter,
        now: Date = Date(),
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) async {
        guard !isReconciling else {
            needsAnotherReconciliation = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            needsAnotherReconciliation = false
            do {
                let planning = try await reader.reminderPlanningSnapshot(
                    now: now,
                    displayTimeZoneIdentifier: displayTimeZoneIdentifier,
                    horizonLocalDays: 14
                )
                let settings = await client.settings()
                let pending = await client.pendingRequests()
                let foreignPendingCount = pending.count {
                    !$0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
                }
                let plan = LocalReminderPlanner.plan(
                    candidates: planning.candidates,
                    settings: settings,
                    now: now,
                    hasEnabledIntent: planning.hasEnabledIntent,
                    foreignPendingCount: foreignPendingCount
                )
                let observation = await LocalReminderReconciler(client: client).reconcile(
                    plan: plan,
                    observedAt: now
                )
                try await writer.updateNotificationCoverage(observation)
                lastErrorCode = observation.lastErrorCode
            } catch {
                lastErrorCode = "reconciliation-unavailable"
            }
        } while needsAnotherReconciliation
    }

    func requestAuthorizationAndReconcile(
        reader: AppReadActor,
        writer: AppDataWriter,
        now: Date = Date(),
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) async {
        do {
            _ = try await client.requestAuthorization()
        } catch {
            lastErrorCode = "authorization-request-failed"
        }
        await reconcile(
            reader: reader,
            writer: writer,
            now: now,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier
        )
    }
}

private struct LocalReminderRuntimeEnvironmentKey: EnvironmentKey {
    static let defaultValue: LocalReminderRuntime? = nil
}

extension EnvironmentValues {
    var localReminderRuntime: LocalReminderRuntime? {
        get { self[LocalReminderRuntimeEnvironmentKey.self] }
        set { self[LocalReminderRuntimeEnvironmentKey.self] = newValue }
    }
}
