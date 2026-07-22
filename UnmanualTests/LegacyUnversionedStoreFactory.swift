import Foundation
import SwiftData
@testable import Unmanual

/// Reproduces the exact unversioned schema/configuration shape used before the
/// data-foundation migration. It deliberately does not use `AppSchemaV1`.
@MainActor
enum LegacyUnversionedStoreFactory {
    static func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema([
            HRTProfile.self,
            CountdownRecord.self,
            RegimenVersion.self,
            JourneyEntry.self,
            LabRecord.self
        ])
        let configuration = ModelConfiguration(
            "LegacyUnversioned",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
