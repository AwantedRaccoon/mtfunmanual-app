import Foundation
import LocalAuthentication

enum DeviceOwnerAuthenticationFailure: Equatable, Sendable {
    case authenticationFailed
    case userCancelled
    case systemCancelled
    case appCancelled
    case notInteractive
    case passcodeNotSet
    case biometryUnavailable
    case biometryNotEnrolled
    case biometryLockedOut
    case unknown
}

enum DeviceOwnerAuthenticationOutcome: Equatable, Sendable {
    case success
    case failure(DeviceOwnerAuthenticationFailure)
}

enum DeviceOwnerAuthenticationAvailability: Equatable, Sendable {
    case available
    case unavailable(DeviceOwnerAuthenticationFailure)
}

@MainActor
protocol DeviceOwnerAuthenticationClient: AnyObject {
    func availability() -> DeviceOwnerAuthenticationAvailability
    func authenticate(
        requestID: UUID,
        reason: String
    ) async -> DeviceOwnerAuthenticationOutcome
    func cancel()
}

@MainActor
final class LocalAuthenticationClient: DeviceOwnerAuthenticationClient {
    private var activeContext: LAContext?
    private var activeRequestID: UUID?

    func availability() -> DeviceOwnerAuthenticationAvailability {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else {
            return .unavailable(Self.failure(for: error))
        }
        return .available
    }

    func authenticate(
        requestID: UUID,
        reason: String
    ) async -> DeviceOwnerAuthenticationOutcome {
        cancel()
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        activeContext = context
        activeRequestID = requestID
        defer {
            if activeRequestID == requestID {
                activeContext = nil
                activeRequestID = nil
            }
            context.invalidate()
        }

        do {
            let accepted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return accepted ? .success : .failure(.authenticationFailed)
        } catch {
            return .failure(Self.failure(for: error as NSError))
        }
    }

    func cancel() {
        activeContext?.invalidate()
        activeContext = nil
        activeRequestID = nil
    }

    private static func failure(
        for error: NSError?
    ) -> DeviceOwnerAuthenticationFailure {
        guard let error,
              error.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: error.code) else {
            return .unknown
        }
        switch code {
        case .authenticationFailed:
            return .authenticationFailed
        case .userCancel, .userFallback:
            return .userCancelled
        case .systemCancel:
            return .systemCancelled
        case .appCancel:
            return .appCancelled
        case .notInteractive:
            return .notInteractive
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometryNotAvailable:
            return .biometryUnavailable
        case .biometryNotEnrolled:
            return .biometryNotEnrolled
        case .biometryLockout:
            return .biometryLockedOut
        default:
            return .unknown
        }
    }
}

#if DEBUG
@MainActor
final class DebugSuccessfulAuthenticationClient:
    DeviceOwnerAuthenticationClient {
    func availability() -> DeviceOwnerAuthenticationAvailability {
        .available
    }

    func authenticate(
        requestID _: UUID,
        reason _: String
    ) async -> DeviceOwnerAuthenticationOutcome {
        .success
    }

    func cancel() {}
}
#endif
