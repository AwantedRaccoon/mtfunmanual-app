import Foundation
import SwiftData

enum HrtJourneyLifecycleEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case migratedSnapshot
    case started
    case firstStartCorrected
    case paused
    case resumed
}

enum HrtJourneyLifecycleEventSource: String, Codable, Equatable, Sendable {
    case migration
    case user
}

@Model
final class HrtJourneyLifecycleEventRecord {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var kindRawValue: String
    var sourceRawValue: String
    var previousEventID: UUID?
    var periodID: UUID?
    var transitionYear: Int?
    var transitionMonth: Int?
    var transitionDay: Int?
    var noteSnapshot: String
    var occurredAt: Date
    var localYear: Int
    var localMonth: Int
    var localDay: Int
    var localHour: Int
    var localMinute: Int
    var localSecond: Int
    var localNanosecond: Int
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var precisionRawValue: String
    var provenanceRawValue: String
    var preFactsDigest: String
    var postFactsDigest: String

    var kind: HrtJourneyLifecycleEventKind? {
        HrtJourneyLifecycleEventKind(rawValue: kindRawValue)
    }

    var source: HrtJourneyLifecycleEventSource? {
        HrtJourneyLifecycleEventSource(rawValue: sourceRawValue)
    }

    var transitionDate: CivilDateFact? {
        guard let transitionYear, let transitionMonth, let transitionDay else {
            return nil
        }
        return try? CivilDateFact(
            year: transitionYear,
            month: transitionMonth,
            day: transitionDay
        )
    }

    var historicalTimestamp: HistoricalTimestamp? {
        guard let localDate = try? CivilDateFact(
            year: localYear,
            month: localMonth,
            day: localDay
        ),
        let localTime = try? HistoricalLocalTime(
            hour: localHour,
            minute: localMinute,
            second: localSecond,
            nanosecond: localNanosecond
        ),
        let precision = HistoricalTimestampPrecision(
            rawValue: precisionRawValue
        ),
        let provenance = HistoricalTimestampProvenance(
            rawValue: provenanceRawValue
        ) else {
            return nil
        }
        return try? HistoricalTimestamp(
            validatingInstant: occurredAt,
            localDate: localDate,
            localTime: localTime,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            precision: precision,
            provenance: provenance
        )
    }

    init(
        id: UUID,
        operationID: UUID,
        kind: HrtJourneyLifecycleEventKind,
        source: HrtJourneyLifecycleEventSource,
        previousEventID: UUID?,
        periodID: UUID?,
        transitionDate: CivilDateFact?,
        noteSnapshot: String,
        timestamp: HistoricalTimestamp,
        preFactsDigest: String,
        postFactsDigest: String
    ) {
        self.id = id
        self.operationID = operationID
        self.kindRawValue = kind.rawValue
        self.sourceRawValue = source.rawValue
        self.previousEventID = previousEventID
        self.periodID = periodID
        self.transitionYear = transitionDate?.year
        self.transitionMonth = transitionDate?.month
        self.transitionDay = transitionDate?.day
        self.noteSnapshot = noteSnapshot
        self.occurredAt = timestamp.instant
        self.localYear = timestamp.localDate.year
        self.localMonth = timestamp.localDate.month
        self.localDay = timestamp.localDate.day
        self.localHour = timestamp.localTime.hour
        self.localMinute = timestamp.localTime.minute
        self.localSecond = timestamp.localTime.second
        self.localNanosecond = timestamp.localTime.nanosecond
        self.timeZoneIdentifier = timestamp.timeZoneIdentifier
        self.utcOffsetSeconds = timestamp.utcOffsetSeconds
        self.precisionRawValue = timestamp.precision.rawValue
        self.provenanceRawValue = timestamp.provenance.rawValue
        self.preFactsDigest = preFactsDigest
        self.postFactsDigest = postFactsDigest
    }
}

@Model
final class HrtJourneyLifecycleBackfillState {
    static let fixedKey = "v8-to-v9-hrt-journey-lifecycle"

    @Attribute(.unique) var taskKey: String
    var sourceSchemaVersion: String
    var initialPeriodCount: Int
    var initialEventCount: Int
    var initialFactsDigest: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = HrtJourneyLifecycleBackfillState.fixedKey,
        sourceSchemaVersion: String,
        initialPeriodCount: Int,
        initialEventCount: Int,
        initialFactsDigest: String,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.taskKey = taskKey
        self.sourceSchemaVersion = sourceSchemaVersion
        self.initialPeriodCount = initialPeriodCount
        self.initialEventCount = initialEventCount
        self.initialFactsDigest = initialFactsDigest
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}
