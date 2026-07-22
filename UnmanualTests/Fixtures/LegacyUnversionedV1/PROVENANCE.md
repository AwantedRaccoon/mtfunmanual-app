# Legacy unversioned V1 fixture provenance

- Purpose: immutable migration input for the data-safety foundation tests.
- Generated: 2026-07-21 with Apple SwiftData from the exact unversioned `Schema([HRTProfile, CountdownRecord, RegimenVersion, JourneyEntry, LabRecord])` shape used before the foundation migration.
- Pre-foundation source commit: `7ebfbd38bb0f31a3104c944fe2116ccac06c0a0f` (`feat: establish V2.5 iOS app baseline`).
- Toolchain: Xcode 26.4 / Swift 6; host macOS.
- Generator: `GenerateLegacyFixture.swift.txt` in this directory (SHA-256 `7ed067669bc76b0e8bc6f154b7dd4baaf17e45912162460c739cdd817560f986`). It used fixed UUIDs, dates and values and copied the quiescent main/WAL/SHM bundle while the legacy container remained open.
- Data declaration: every identifier, date, regimen, journey entry and lab value is deterministic synthetic test data created by that generator. No record is real, user-derived or copied from a production database.
- License: the generator, this provenance record and the SQLite main/WAL/SHM bundle are project-owned test support materials provided under MPL-2.0; see the repository root `LICENSE` and `LICENSE-SCOPE.md`.
- Historical `Models.swift` SHA-256: `b653d8d808b03c8428781b48324c7415ac881fe25934397880d4e562e8323d78`.
- Generator compilation used the working-tree `Models.swift` SHA-256 `a6162a0b007ba437e7107bd48dd4c0bd94ee4bb8771a319dd20da3359b6b53c0`; its only schema-relevant-file diff from the historical file is the non-persistent `Sendable` conformance on `JourneyEntryKind`.
- Limitation: this repository has no previously shipped App binary or user database. This is a frozen source-reconstructed artifact, not a claim that a production user file was collected.

SHA-256:

```text
d9146783c2ac547cb928d49575b413f5c809798b7966a25993b303bf076bc46c  legacy-unversioned.sqlite
990cd5758c9452546266e8275e654a8d3487981ac4258a0ed3521dde716c50a0  legacy-unversioned.sqlite-shm
3dd20dac4b7ce743b798659e569d6bd0536c171f87a35777213dcfcff2f5ed34  legacy-unversioned.sqlite-wal
```

Tests must copy all three files to a temporary location before opening them and must verify that these source hashes remain unchanged.
