import Foundation

enum DataInventoryManifestBuilder {
    static func notificationCategories(
        observations:
            [DataInventoryNotificationRequestObservation]
    ) throws -> [DataInventoryCategory] {
        let snapshots =
            DataInventoryNotificationSnapshotFactory.categories(
                observations: observations
            )
        let specifications = DataInventoryTaxonomy
            .categorySpecifications
            .filter { $0.kind == .notification }
        return try specifications.map { specification in
            guard let snapshot = snapshots.first(
                where: { $0.key == specification.key }
            ) else {
                throw DataInventoryValidationError
                    .invalidNotificationSnapshot
            }
            return try materialize(
                snapshot,
                specification: specification
            )
        }
        .sorted { asciiLess($0.key, $1.key) }
    }

    static func makeManifest(
        generationID: UUID,
        datasetID: UUID,
        nextLocalRevision: Int64,
        capturedAt: Date,
        snapshots: [DataInventoryCategorySnapshot]
    ) throws -> DataInventoryManifest {
        let specifications = DataInventoryTaxonomy.categorySpecifications
            .sorted { asciiLess($0.key, $1.key) }
        let grouped = Dictionary(grouping: snapshots, by: \.key)
        let hasUnknownOrDuplicateCategory =
            snapshots.contains { snapshot in
                !specifications.contains { specification in
                    specification.key == snapshot.key
                }
            }
            || grouped.values.contains { $0.count != 1 }

        let generationPreflight = generationPreflight(
            generationID: generationID,
            grouped: grouped
        )
        let databasePreflight = databasePreflight(
            datasetID: datasetID,
            grouped: grouped
        )
        let taxonomyIsValid =
            DataInventoryTaxonomy.hasExactModelPartition
            && specifications.map(\.key)
                == specifications.map(\.key).sorted(by: asciiLess)
            && Set(specifications.map(\.key)).count == specifications.count
            && DataInventoryTaxonomy.unmanagedBoundaries.map(\.key)
                == DataInventoryTaxonomy.unmanagedBoundaries
                    .map(\.key)
                    .sorted(by: asciiLess)

        let categories = try specifications.map { specification in
            guard taxonomyIsValid,
                  !generationPreflight.failedKeys.contains(specification.key),
                  !databasePreflight.failedKeys.contains(specification.key),
                  let candidates = grouped[specification.key],
                  candidates.count == 1,
                  let snapshot = candidates.first,
                  snapshot.kind == specification.kind else {
                return failedCategory(specification)
            }
            return try materialize(
                snapshot,
                specification: specification
            )
        }

        let isComplete =
            !hasUnknownOrDuplicateCategory
            && taxonomyIsValid
            && generationPreflight.isComplete
            && databasePreflight.isComplete
            && nextLocalRevision > 0
            && categories.allSatisfy { $0.status == .complete }
        let completeness: DataInventoryCompleteness =
            isComplete ? .complete : .incomplete
        let boundaries = DataInventoryTaxonomy.unmanagedBoundaries
        let stateFields = try manifestFields(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: nextLocalRevision,
            capturedAt: nil,
            completeness: completeness,
            stateDigest: nil,
            categories: categories,
            boundaries: boundaries
        )
        let stateDigest = try RecordDigestV1.sha256Hex(
            recordType: "DataInventoryStateV1",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: "data-inventory-state-v1"
            ),
            fields: stateFields
        )
        let manifestDigest = try RecordDigestV1.sha256Hex(
            recordType: "DataInventoryManifestV1",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: "data-inventory-manifest-v1"
            ),
            fields: try manifestFields(
                generationID: generationID,
                datasetID: datasetID,
                nextLocalRevision: nextLocalRevision,
                capturedAt: capturedAt,
                completeness: completeness,
                stateDigest: stateDigest,
                categories: categories,
                boundaries: boundaries
            )
        )
        return DataInventoryManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: nextLocalRevision,
            capturedAt: capturedAt,
            completeness: completeness,
            categories: categories,
            unmanagedBoundaries: boundaries,
            stateDigest: stateDigest,
            manifestDigest: manifestDigest
        )
    }

    static func makeManifest(
        generationID: UUID,
        datasetID: UUID,
        nextLocalRevision: Int64,
        capturedAt: Date,
        provider: any DataInventorySnapshotProvider
    ) async throws -> DataInventoryManifest {
        let snapshots: [DataInventoryCategorySnapshot]
        do {
            snapshots = try await provider.categorySnapshots()
        } catch {
            snapshots = []
        }
        return try makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: nextLocalRevision,
            capturedAt: capturedAt,
            snapshots: snapshots
        )
    }

    private static func materialize(
        _ snapshot: DataInventoryCategorySnapshot,
        specification: DataInventoryCategorySpecification
    ) throws -> DataInventoryCategory {
        guard snapshot.key == specification.key,
              snapshot.kind == specification.kind else {
            return failedCategory(specification)
        }

        do {
            switch snapshot.payload {
            case let .database(database):
                guard specification.kind == .database else {
                    return failedCategory(specification)
                }
                return try databaseCategory(
                    specification: specification,
                    snapshot: database
                )
            case let .regularFiles(files):
                guard specification.kind == .fileTree
                        || specification.kind == .control else {
                    return failedCategory(specification)
                }
                return try regularFileCategory(
                    specification: specification,
                    files: files
                )
            case let .generations(generations):
                guard specification.kind == .generation else {
                    return failedCategory(specification)
                }
                return try generationCategory(
                    specification: specification,
                    generations: generations
                )
            case let .notifications(notifications):
                guard specification.kind == .notification else {
                    return failedCategory(specification)
                }
                return try notificationCategory(
                    specification: specification,
                    notifications: notifications
                )
            case .failed:
                return failedCategory(specification)
            }
        } catch {
            return failedCategory(specification)
        }
    }

    private static func databaseCategory(
        specification: DataInventoryCategorySpecification,
        snapshot: DataInventoryDatabaseSnapshot
    ) throws -> DataInventoryCategory {
        guard let expectedModels =
                DataInventoryTaxonomy.databaseModelsByCategory[specification.key],
              Set(snapshot.modelRowCounts.keys) == Set(expectedModels),
              snapshot.modelRowCounts.values.allSatisfy({
                  $0 >= 0
                      && $0 <= Int64(
                          DataInventoryTaxonomy.maximumRowsPerModel
                      )
              }),
              try checkedSum(snapshot.modelRowCounts.values)
                == Int64(snapshot.entries.count) else {
            throw DataInventoryValidationError.invalidDatabaseSnapshot
        }

        let sortedEntries = try sortedDatabaseEntries(snapshot.entries)
        var fields = commonCategoryFields(
            specification: specification,
            itemCount: Int64(sortedEntries.count),
            byteCount: nil,
            entryCount: Int64(sortedEntries.count)
        )
        for (index, entry) in sortedEntries.enumerated() {
            let prefix = "entry.\(index)"
            switch entry {
            case let .fact(
                _,
                _,
                _,
                _,
                recordKey,
                localRevision,
                _,
                digestHex
            ):
                fields.append(.init("\(prefix).variant", .string("fact")))
                fields.append(.init("\(prefix).recordKey", .string(recordKey)))
                fields.append(.init("\(prefix).localRevision", .integer(localRevision)))
                fields.append(.init("\(prefix).digestHex", .string(digestHex)))
            case let .revision(
                recordKey,
                recordType,
                recordID,
                revisionDatasetID,
                localRevision,
                digestVersion,
                committedAt,
                digestHex
            ):
                fields.append(.init("\(prefix).variant", .string("revision")))
                fields.append(.init("\(prefix).recordKey", .string(recordKey)))
                fields.append(.init("\(prefix).recordType", .string(recordType)))
                fields.append(.init("\(prefix).recordID", .uuid(recordID)))
                fields.append(.init("\(prefix).datasetID", .uuid(revisionDatasetID)))
                fields.append(.init("\(prefix).localRevision", .integer(localRevision)))
                fields.append(.init("\(prefix).digestVersion", .integer(digestVersion)))
                fields.append(
                    .init(
                        "\(prefix).committedAt",
                        try RecordDigestV1.timestampValue(committedAt)
                    )
                )
                fields.append(.init("\(prefix).digestHex", .string(digestHex)))
            case let .control(modelType, stableIdentity):
                fields.append(.init("\(prefix).variant", .string("control")))
                fields.append(.init("\(prefix).modelType", .string(modelType)))
                fields.append(
                    .init(
                        "\(prefix).stableIdentity",
                        .string(stableIdentity)
                    )
                )
            }
        }
        return try completeCategory(
            specification: specification,
            itemCount: Int64(sortedEntries.count),
            byteCount: nil,
            fields: fields
        )
    }

    private static func regularFileCategory(
        specification: DataInventoryCategorySpecification,
        files: [DataInventoryRegularFileSnapshot]
    ) throws -> DataInventoryCategory {
        let sortedFiles = try validatedFiles(files)
        let byteCount = try checkedSum(sortedFiles.map(\.byteCount))
        var fields = commonCategoryFields(
            specification: specification,
            itemCount: Int64(sortedFiles.count),
            byteCount: byteCount,
            entryCount: Int64(sortedFiles.count)
        )
        for (index, file) in sortedFiles.enumerated() {
            let prefix = "entry.\(index)"
            fields.append(.init("\(prefix).relativePath", .string(file.relativePath)))
            fields.append(.init("\(prefix).fileType", .string("regular")))
            fields.append(.init("\(prefix).byteCount", .integer(file.byteCount)))
            fields.append(.init("\(prefix).sha256Hex", .string(file.sha256Hex)))
        }
        return try completeCategory(
            specification: specification,
            itemCount: Int64(sortedFiles.count),
            byteCount: byteCount,
            fields: fields
        )
    }

    private static func generationCategory(
        specification: DataInventoryCategorySpecification,
        generations: [DataInventoryGenerationSnapshot]
    ) throws -> DataInventoryCategory {
        guard specification.key != "storage.generation.invalid"
                || generations.isEmpty else {
            throw DataInventoryValidationError.invalidGenerationSnapshot
        }
        let sortedGenerations = try generations
            .map { try materializeGeneration($0, categoryKey: specification.key) }
            .sorted { asciiLess($0.snapshot.entryName, $1.snapshot.entryName) }
        guard Set(sortedGenerations.map(\.snapshot.entryName)).count
                == sortedGenerations.count else {
            throw DataInventoryValidationError.duplicateIdentity
        }
        let byteCount = try checkedSum(sortedGenerations.map(\.byteCount))
        var fields = commonCategoryFields(
            specification: specification,
            itemCount: Int64(sortedGenerations.count),
            byteCount: byteCount,
            entryCount: Int64(sortedGenerations.count)
        )
        for (index, generation) in sortedGenerations.enumerated() {
            let prefix = "entry.\(index)"
            let snapshot = generation.snapshot
            fields.append(.init("\(prefix).entryName", .string(snapshot.entryName)))
            fields.append(
                .init(
                    "\(prefix).generationID",
                    snapshot.generationID.map(RecordDigestV1.Value.uuid) ?? .null
                )
            )
            fields.append(
                .init(
                    "\(prefix).primaryClassification",
                    .string(snapshot.primaryClassification.rawValue)
                )
            )
            fields.append(
                .init(
                    "\(prefix).journalRoleCount",
                    .integer(Int64(generation.roles.count))
                )
            )
            for (roleIndex, role) in generation.roles.enumerated() {
                fields.append(
                    .init(
                        "\(prefix).journalRole.\(roleIndex)",
                        .string(role.rawValue)
                    )
                )
            }
            fields.append(
                .init(
                    "\(prefix).relativePath",
                    .string(snapshot.relativePath)
                )
            )
            fields.append(.init("\(prefix).byteCount", .integer(generation.byteCount)))
            fields.append(.init("\(prefix).treeDigest", .string(generation.treeDigest)))
        }
        return try completeCategory(
            specification: specification,
            itemCount: Int64(sortedGenerations.count),
            byteCount: byteCount,
            fields: fields
        )
    }

    private static func notificationCategory(
        specification: DataInventoryCategorySpecification,
        notifications: [DataInventoryNotificationSnapshot]
    ) throws -> DataInventoryCategory {
        let sortedNotifications = notifications.sorted {
            asciiLess($0.identifier, $1.identifier)
        }
        guard sortedNotifications.allSatisfy({
            $0.categoryKey == specification.key
                && $0.identifier.hasPrefix($0.namespace.identifierPrefix)
                && !$0.identifier.isEmpty
        }),
        Set(sortedNotifications.map(\.identifier)).count
            == sortedNotifications.count else {
            throw DataInventoryValidationError.invalidNotificationSnapshot
        }
        var fields = commonCategoryFields(
            specification: specification,
            itemCount: Int64(sortedNotifications.count),
            byteCount: nil,
            entryCount: Int64(sortedNotifications.count)
        )
        for (index, notification) in sortedNotifications.enumerated() {
            let prefix = "entry.\(index)"
            fields.append(
                .init(
                    "\(prefix).namespace",
                    .string(notification.namespace.rawValue)
                )
            )
            fields.append(
                .init(
                    "\(prefix).deliveryState",
                    .string(notification.deliveryState.rawValue)
                )
            )
            fields.append(
                .init(
                    "\(prefix).identifier",
                    .string(notification.identifier)
                )
            )
        }
        return try completeCategory(
            specification: specification,
            itemCount: Int64(sortedNotifications.count),
            byteCount: nil,
            fields: fields
        )
    }

    private static func completeCategory(
        specification: DataInventoryCategorySpecification,
        itemCount: Int64,
        byteCount: Int64?,
        fields: [RecordDigestV1.Field]
    ) throws -> DataInventoryCategory {
        let digest = try RecordDigestV1.sha256Hex(
            recordType: "DataInventoryCategoryV1",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: "data-inventory-category:" + specification.key
            ),
            fields: fields
        )
        return DataInventoryCategory(
            key: specification.key,
            kind: specification.kind,
            status: .complete,
            itemCount: itemCount,
            byteCount: byteCount,
            retainedSensitiveCount: itemCount,
            identityDigest: digest
        )
    }

    private static func failedCategory(
        _ specification: DataInventoryCategorySpecification
    ) -> DataInventoryCategory {
        DataInventoryCategory(
            key: specification.key,
            kind: specification.kind,
            status: .failed,
            itemCount: nil,
            byteCount: nil,
            retainedSensitiveCount: nil,
            identityDigest: nil
        )
    }

    private static func commonCategoryFields(
        specification: DataInventoryCategorySpecification,
        itemCount: Int64,
        byteCount: Int64?,
        entryCount: Int64
    ) -> [RecordDigestV1.Field] {
        [
            .init("key", .string(specification.key)),
            .init("kind", .string(specification.kind.rawValue)),
            .init("itemCount", .integer(itemCount)),
            .init("byteCount", byteCount.map(RecordDigestV1.Value.integer) ?? .null),
            .init("retainedSensitiveCount", .integer(itemCount)),
            .init("entryCount", .integer(entryCount))
        ]
    }

    private static func manifestFields(
        generationID: UUID,
        datasetID: UUID,
        nextLocalRevision: Int64,
        capturedAt: Date?,
        completeness: DataInventoryCompleteness,
        stateDigest: String?,
        categories: [DataInventoryCategory],
        boundaries: [DataInventoryBoundary]
    ) throws -> [RecordDigestV1.Field] {
        var fields: [RecordDigestV1.Field] = [
            .init("generationID", .uuid(generationID)),
            .init("datasetID", .uuid(datasetID)),
            .init("nextLocalRevision", .integer(nextLocalRevision)),
            .init("completeness", .string(completeness.rawValue)),
            .init("categoryCount", .integer(Int64(categories.count)))
        ]
        if let capturedAt {
            fields.append(
                .init(
                    "capturedAt",
                    try RecordDigestV1.timestampValue(capturedAt)
                )
            )
        }
        if let stateDigest {
            fields.append(.init("stateDigest", .string(stateDigest)))
        }
        for (index, category) in categories.enumerated() {
            let prefix = "category.\(index)"
            fields.append(.init("\(prefix).key", .string(category.key)))
            fields.append(.init("\(prefix).kind", .string(category.kind.rawValue)))
            fields.append(.init("\(prefix).status", .string(category.status.rawValue)))
            fields.append(
                .init(
                    "\(prefix).itemCount",
                    category.itemCount.map(RecordDigestV1.Value.integer) ?? .null
                )
            )
            fields.append(
                .init(
                    "\(prefix).byteCount",
                    category.byteCount.map(RecordDigestV1.Value.integer) ?? .null
                )
            )
            fields.append(
                .init(
                    "\(prefix).retainedSensitiveCount",
                    category.retainedSensitiveCount
                        .map(RecordDigestV1.Value.integer) ?? .null
                )
            )
            fields.append(
                .init(
                    "\(prefix).identityDigest",
                    category.identityDigest.map(RecordDigestV1.Value.string) ?? .null
                )
            )
        }
        fields.append(.init("boundaryCount", .integer(Int64(boundaries.count))))
        for (index, boundary) in boundaries.enumerated() {
            let prefix = "boundary.\(index)"
            fields.append(.init("\(prefix).key", .string(boundary.key)))
            fields.append(.init("\(prefix).state", .string(boundary.state.rawValue)))
        }
        return fields
    }

    private static func sortedDatabaseEntries(
        _ entries: [DataInventoryDatabaseEntry]
    ) throws -> [DataInventoryDatabaseEntry] {
        for entry in entries {
            switch entry {
            case let .fact(
                modelType,
                recordType,
                _,
                _,
                recordKey,
                localRevision,
                digestVersion,
                digestHex
            ):
                guard modelType == recordType,
                      !modelType.isEmpty,
                      !recordKey.isEmpty,
                      localRevision > 0,
                      digestVersion > 0,
                      isDigestHex(digestHex) else {
                    throw DataInventoryValidationError.invalidDatabaseSnapshot
                }
            case let .revision(
                recordKey,
                recordType,
                _,
                _,
                localRevision,
                digestVersion,
                committedAt,
                digestHex
            ):
                guard !recordKey.isEmpty,
                      !recordType.isEmpty,
                      localRevision > 0,
                      digestVersion > 0,
                      (try? RecordDigestV1.timestampMicroseconds(committedAt)) != nil,
                      isDigestHex(digestHex) else {
                    throw DataInventoryValidationError.invalidDatabaseSnapshot
                }
            case let .control(modelType, stableIdentity):
                guard DataInventoryTaxonomy.allowedUnrevisionedControlModels
                    .contains(modelType),
                    !stableIdentity.isEmpty else {
                    throw DataInventoryValidationError.invalidDatabaseSnapshot
                }
            }
        }
        let sorted = entries.sorted(by: databaseEntryLess)
        guard !zip(sorted, sorted.dropFirst()).contains(where: {
            !databaseEntryLess($0.0, $0.1)
                && !databaseEntryLess($0.1, $0.0)
        }) else {
            throw DataInventoryValidationError.duplicateIdentity
        }
        return sorted
    }

    private static func databaseEntryLess(
        _ lhs: DataInventoryDatabaseEntry,
        _ rhs: DataInventoryDatabaseEntry
    ) -> Bool {
        let lhsRank = databaseEntryRank(lhs)
        let rhsRank = databaseEntryRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        switch (lhs, rhs) {
        case let (
            .fact(_, _, _, _, lhsRecordKey, _, _, _),
            .fact(_, _, _, _, rhsRecordKey, _, _, _)
        ):
            return asciiLess(lhsRecordKey, rhsRecordKey)
        case let (
            .revision(lhsRecordKey, _, _, _, lhsRevision, _, _, _),
            .revision(rhsRecordKey, _, _, _, rhsRevision, _, _, _)
        ):
            if lhsRecordKey != rhsRecordKey {
                return asciiLess(lhsRecordKey, rhsRecordKey)
            }
            return lhsRevision < rhsRevision
        case let (
            .control(lhsModelType, lhsIdentity),
            .control(rhsModelType, rhsIdentity)
        ):
            return asciiLess(
                lhsModelType + ":" + lhsIdentity,
                rhsModelType + ":" + rhsIdentity
            )
        default:
            return false
        }
    }

    private static func databaseEntryRank(
        _ entry: DataInventoryDatabaseEntry
    ) -> Int {
        switch entry {
        case .fact:
            0
        case .revision:
            1
        case .control:
            2
        }
    }

    private static func validatedFiles(
        _ files: [DataInventoryRegularFileSnapshot]
    ) throws -> [DataInventoryRegularFileSnapshot] {
        guard files.allSatisfy({
            isSafeRelativePath($0.relativePath)
                && $0.byteCount >= 0
                && isDigestHex($0.sha256Hex)
        }) else {
            throw DataInventoryValidationError.invalidFileSnapshot
        }
        let sorted = files.sorted {
            asciiLess($0.relativePath, $1.relativePath)
        }
        guard Set(sorted.map(\.relativePath)).count == sorted.count else {
            throw DataInventoryValidationError.duplicateIdentity
        }
        return sorted
    }

    private struct MaterializedGeneration {
        let snapshot: DataInventoryGenerationSnapshot
        let roles: [DataInventoryGenerationJournalRole]
        let byteCount: Int64
        let treeDigest: String
    }

    private static func materializeGeneration(
        _ snapshot: DataInventoryGenerationSnapshot,
        categoryKey: String
    ) throws -> MaterializedGeneration {
        guard snapshot.primaryClassification.categoryKey == categoryKey,
              snapshot.primaryClassification != .invalid,
              let generationID = snapshot.generationID,
              snapshot.entryName
                == generationID.uuidString.lowercased(),
              snapshot.relativePath
                == "Unmanual/Generations/\(snapshot.entryName)",
              snapshot.entryName
                == snapshot.entryName.precomposedStringWithCanonicalMapping,
              (snapshot.primaryClassification == .active
                  && snapshot.scope == .activeLogicalOverlay)
                || (snapshot.primaryClassification != .active
                    && snapshot.scope == .closedFullTree) else {
            throw DataInventoryValidationError.invalidGenerationSnapshot
        }
        let roles = snapshot.journalRoles.sorted {
            asciiLess($0.rawValue, $1.rawValue)
        }
        guard Set(roles.map(\.rawValue)).count == roles.count else {
            throw DataInventoryValidationError.duplicateIdentity
        }
        let files = try validatedFiles(snapshot.files)
        guard snapshot.scope != .activeLogicalOverlay
                || files.allSatisfy({
                    !DataInventoryGenerationTreeAudit
                        .isExcludedFromActiveDigest($0.relativePath)
                }) else {
            throw DataInventoryValidationError.invalidGenerationSnapshot
        }
        let byteCount = try checkedSum(files.map(\.byteCount))
        var fields: [RecordDigestV1.Field] = [
            .init("entryName", .string(snapshot.entryName)),
            .init("generationID", .uuid(generationID)),
            .init(
                "primaryClassification",
                .string(snapshot.primaryClassification.rawValue)
            ),
            .init("journalRoleCount", .integer(Int64(roles.count))),
            .init("fileCount", .integer(Int64(files.count))),
            .init("scopeRawValue", .string(snapshot.scope.rawValue)),
            .init(
                "excludedCount",
                .integer(Int64(snapshot.scope.excludedPaths.count))
            )
        ]
        for (index, role) in roles.enumerated() {
            fields.append(.init("journalRole.\(index)", .string(role.rawValue)))
        }
        for (index, excluded) in snapshot.scope.excludedPaths.enumerated() {
            fields.append(.init("excluded.\(index)", .string(excluded)))
        }
        for (index, file) in files.enumerated() {
            let prefix = "file.\(index)"
            fields.append(.init("\(prefix).relativePath", .string(file.relativePath)))
            fields.append(.init("\(prefix).fileType", .string("regular")))
            fields.append(.init("\(prefix).byteCount", .integer(file.byteCount)))
            fields.append(.init("\(prefix).sha256Hex", .string(file.sha256Hex)))
        }
        let treeDigest = try RecordDigestV1.sha256Hex(
            recordType: "DataInventoryGenerationTreeV1",
            recordID: generationID,
            fields: fields
        )
        return MaterializedGeneration(
            snapshot: snapshot,
            roles: roles,
            byteCount: byteCount,
            treeDigest: treeDigest
        )
    }

    private struct GenerationPreflight {
        let failedKeys: Set<String>
        let isComplete: Bool
    }

    private struct DatabaseFactProof: Equatable {
        let recordType: String
        let recordID: UUID
        let datasetID: UUID
        let localRevision: Int64
        let digestVersion: Int64
        let digestHex: String
    }

    private struct DatabaseRevisionProof: Equatable {
        let recordType: String
        let recordID: UUID
        let datasetID: UUID
        let localRevision: Int64
        let digestVersion: Int64
        let digestHex: String
    }

    private struct DatabasePreflight {
        let failedKeys: Set<String>
        let isComplete: Bool
    }

    private static func databasePreflight(
        datasetID: UUID,
        grouped: [String: [DataInventoryCategorySnapshot]]
    ) -> DatabasePreflight {
        let specifications =
            DataInventoryTaxonomy.categorySpecifications.filter {
                $0.kind == .database
            }
        let allKeys = Set(specifications.map(\.key))
        var factsByRecordKey: [String: DatabaseFactProof] = [:]
        var revisionsByRecordKey: [String: DatabaseRevisionProof] = [:]
        var controlIdentities: Set<String> = []

        for specification in specifications {
            guard let expectedModels =
                    DataInventoryTaxonomy
                        .databaseModelsByCategory[specification.key],
                  let candidates = grouped[specification.key],
                  candidates.count == 1,
                  let candidate = candidates.first,
                  candidate.kind == .database,
                  case let .database(snapshot) = candidate.payload,
                  Set(snapshot.modelRowCounts.keys)
                    == Set(expectedModels) else {
                return DatabasePreflight(
                    failedKeys: allKeys,
                    isComplete: false
                )
            }
            var observedRowCounts: [String: Int64] = [:]
            for entry in snapshot.entries {
                switch entry {
                case let .fact(
                    modelType,
                    recordType,
                    recordID,
                    factDatasetID,
                    recordKey,
                    localRevision,
                    digestVersion,
                    digestHex
                ):
                    let expectedRecordKey = recordType + ":"
                        + recordID.uuidString.lowercased()
                    guard expectedModels.contains(modelType),
                          modelType == recordType,
                          modelType != "RecordRevision",
                          !DataInventoryTaxonomy
                            .allowedUnrevisionedControlModels
                            .contains(modelType),
                          recordKey == expectedRecordKey,
                          factDatasetID == datasetID,
                          factsByRecordKey.updateValue(
                              DatabaseFactProof(
                                  recordType: recordType,
                                  recordID: recordID,
                                  datasetID: factDatasetID,
                                  localRevision: localRevision,
                                  digestVersion: digestVersion,
                                  digestHex: digestHex
                              ),
                              forKey: recordKey
                          ) == nil else {
                        return DatabasePreflight(
                            failedKeys: allKeys,
                            isComplete: false
                        )
                    }
                    observedRowCounts[modelType, default: 0] += 1
                case let .revision(
                    recordKey,
                    recordType,
                    recordID,
                    revisionDatasetID,
                    localRevision,
                    digestVersion,
                    _,
                    digestHex
                ):
                    let expectedRecordKey = recordType + ":"
                        + recordID.uuidString.lowercased()
                    guard specification.key == "db.audit",
                          expectedModels.contains("RecordRevision"),
                          recordKey == expectedRecordKey,
                          revisionDatasetID == datasetID,
                          revisionsByRecordKey.updateValue(
                              DatabaseRevisionProof(
                                  recordType: recordType,
                                  recordID: recordID,
                                  datasetID: revisionDatasetID,
                                  localRevision: localRevision,
                                  digestVersion: digestVersion,
                                  digestHex: digestHex
                              ),
                              forKey: recordKey
                          ) == nil else {
                        return DatabasePreflight(
                            failedKeys: allKeys,
                            isComplete: false
                        )
                    }
                    observedRowCounts["RecordRevision", default: 0] += 1
                case let .control(modelType, stableIdentity):
                    let identity = modelType + ":" + stableIdentity
                    guard expectedModels.contains(modelType),
                          DataInventoryTaxonomy
                            .allowedUnrevisionedControlModels
                            .contains(modelType),
                          controlIdentities.insert(identity).inserted else {
                        return DatabasePreflight(
                            failedKeys: allKeys,
                            isComplete: false
                        )
                    }
                    observedRowCounts[modelType, default: 0] += 1
                }
            }
            guard snapshot.modelRowCounts.allSatisfy({
                observedRowCounts[$0.key, default: 0] == $0.value
            }) else {
                return DatabasePreflight(
                    failedKeys: allKeys,
                    isComplete: false
                )
            }
        }

        guard factsByRecordKey.count == revisionsByRecordKey.count,
              factsByRecordKey.allSatisfy({
                  guard let revision = revisionsByRecordKey[$0.key] else {
                      return false
                  }
                  return DatabaseRevisionProof(
                      recordType: $0.value.recordType,
                      recordID: $0.value.recordID,
                      datasetID: $0.value.datasetID,
                      localRevision: $0.value.localRevision,
                      digestVersion: $0.value.digestVersion,
                      digestHex: $0.value.digestHex
                  ) == revision
              }) else {
            return DatabasePreflight(
                failedKeys: allKeys,
                isComplete: false
            )
        }
        return DatabasePreflight(failedKeys: [], isComplete: true)
    }

    private static func generationPreflight(
        generationID: UUID,
        grouped: [String: [DataInventoryCategorySnapshot]]
    ) -> GenerationPreflight {
        let generationSpecifications =
            DataInventoryTaxonomy.categorySpecifications.filter {
                $0.kind == .generation
            }
        var generations: [DataInventoryGenerationSnapshot] = []
        var failedKeys: Set<String> = []
        for specification in generationSpecifications {
            guard let candidates = grouped[specification.key],
                  candidates.count == 1,
                  let candidate = candidates.first,
                  candidate.kind == .generation,
                  case let .generations(values) = candidate.payload else {
                failedKeys.insert(specification.key)
                continue
            }
            if specification.key == "storage.generation.invalid",
               !values.isEmpty {
                failedKeys.insert(specification.key)
            } else {
                generations.append(contentsOf: values)
            }
        }
        let active = generations.filter {
            $0.primaryClassification == .active
        }
        let uniqueEntryNames =
            Set(generations.map(\.entryName)).count == generations.count
        let validActive =
            active.count == 1
            && active.first?.generationID == generationID
        if !uniqueEntryNames || !validActive {
            failedKeys.formUnion(generationSpecifications.map(\.key))
        }
        return GenerationPreflight(
            failedKeys: failedKeys,
            isComplete: failedKeys.isEmpty
        )
    }

    private static func checkedSum<S: Sequence>(
        _ values: S
    ) throws -> Int64 where S.Element == Int64 {
        var result: Int64 = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw DataInventoryValidationError.countOverflow
            }
            result = addition.partialValue
        }
        return result
    }

    private static func isDigestHex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard value == normalized,
              !value.isEmpty,
              !value.hasPrefix("/") else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func asciiLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private enum DataInventoryValidationError: Error {
        case countOverflow
        case duplicateIdentity
        case invalidDatabaseSnapshot
        case invalidFileSnapshot
        case invalidGenerationSnapshot
        case invalidNotificationSnapshot
    }
}
