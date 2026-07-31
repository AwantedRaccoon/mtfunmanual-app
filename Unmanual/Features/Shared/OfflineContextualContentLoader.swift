import Foundation

enum OfflineContextualContentResourcePolicy {
    static var exposure: OfflineContextualContentExposure {
#if DEBUG
        .candidate
#else
        .release
#endif
    }
}

struct OfflineContextualContentLoader: Sendable {
    let load:
        @Sendable () async
            -> OfflineContextualContentLoadState

    static var live: Self {
        Self {
            let exposure =
                OfflineContextualContentResourcePolicy.exposure
            return await Task.detached(
                priority: .userInitiated
            ) {
                OfflineContextualContentRepository(
                    runtimeBundle: .main,
                    exposure: exposure,
                    statusDate: Date()
                ).state
            }.value
        }
    }

    static func immediate(
        _ state: OfflineContextualContentLoadState
    ) -> Self {
        Self { state }
    }
}
