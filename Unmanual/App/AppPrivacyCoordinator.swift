import Foundation
import Observation
import SwiftUI

enum AppPrivacySceneState: Equatable, Sendable {
    case active
    case inactive
    case background

    init(_ phase: ScenePhase) {
        switch phase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }
}

enum AppPrivacyGateState: Equatable, Sendable {
    case bootstrapping
    case disabled
    case locked(message: String?)
    case authenticating(requestID: UUID)
    case unlocked
    case unavailable(message: String)
}

struct AppPrivacyAuthorizationGrant: Equatable, Sendable {
    let operationID: UUID
    let generationID: UUID
}

enum AppPrivacyCoordinatorFailure: Error, Equatable, Sendable {
    case unavailable
    case authenticationFailed
    case staleRequest
}

@MainActor
@Observable
final class AppPrivacyCoordinator {
    private(set) var gateState: AppPrivacyGateState = .bootstrapping
    private(set) var snapshot: PrivacyControlSnapshot?
    private(set) var generationID: UUID?
    private(set) var sceneState: AppPrivacySceneState = .inactive

    private let client: any DeviceOwnerAuthenticationClient
    private var activeRequestID: UUID?

    init(client: any DeviceOwnerAuthenticationClient) {
        self.client = client
    }

    var permitsSensitiveRoot: Bool {
        guard sceneState == .active else { return false }
        switch gateState {
        case .disabled, .unlocked:
            return true
        default:
            return false
        }
    }

    func permitsSensitiveRoot(for generationID: UUID) -> Bool {
        self.generationID == generationID && permitsSensitiveRoot
    }

    var appLockEnabled: Bool {
        snapshot?.appLockEnabled == true
    }

    func bind(
        reader: any AppPrivacyControlReader,
        generationID: UUID
    ) async {
        invalidateRequest()
        self.generationID = generationID
        snapshot = nil
        gateState = .bootstrapping
        do {
            let loaded = try await reader.privacyControlSnapshot()
            guard self.generationID == generationID else { return }
            snapshot = loaded
            gateState = loaded.appLockEnabled
                ? .locked(message: nil)
                : .disabled
        } catch {
            guard self.generationID == generationID else { return }
            gateState = .unavailable(
                message: "本地隐私设置没有通过完整性检查。"
            )
        }
    }

    func handleSceneState(_ next: AppPrivacySceneState) {
        sceneState = next
        guard next == .background else { return }
        invalidateRequest()
        if snapshot?.appLockEnabled == true {
            gateState = .locked(message: nil)
        }
    }

    func unlock() async {
        guard sceneState == .active,
              let generationID,
              snapshot?.appLockEnabled == true else {
            return
        }
        let requestID = UUID()
        activeRequestID = requestID
        gateState = .authenticating(requestID: requestID)
        let outcome = await client.authenticate(
            requestID: requestID,
            reason: "解锁本机资料"
        )
        guard activeRequestID == requestID else {
            return
        }
        guard self.generationID == generationID,
              sceneState == .active,
              snapshot?.appLockEnabled == true else {
            activeRequestID = nil
            if self.generationID == generationID,
               snapshot?.appLockEnabled == true {
                gateState = .locked(message: nil)
            }
            return
        }
        activeRequestID = nil
        switch outcome {
        case .success:
            gateState = .unlocked
        case let .failure(reason):
            gateState = .locked(
                message: Self.userMessage(for: reason)
            )
        }
    }

    func authorizeSettingChange(
        reason: String
    ) async throws -> AppPrivacyAuthorizationGrant {
        guard sceneState == .active,
              let generationID,
              snapshot != nil else {
            throw AppPrivacyCoordinatorFailure.staleRequest
        }
        guard client.availability() == .available else {
            throw AppPrivacyCoordinatorFailure.unavailable
        }
        let requestID = UUID()
        activeRequestID = requestID
        let outcome = await client.authenticate(
            requestID: requestID,
            reason: reason
        )
        guard activeRequestID == requestID,
              self.generationID == generationID,
              sceneState == .active else {
            throw AppPrivacyCoordinatorFailure.staleRequest
        }
        activeRequestID = nil
        guard outcome == .success else {
            throw AppPrivacyCoordinatorFailure.authenticationFailed
        }
        return AppPrivacyAuthorizationGrant(
            operationID: requestID,
            generationID: generationID
        )
    }

    func acceptCommitted(
        _ snapshot: PrivacyControlSnapshot,
        generationID: UUID
    ) throws {
        guard self.generationID == generationID else {
            throw AppPrivacyCoordinatorFailure.staleRequest
        }
        invalidateRequest()
        self.snapshot = snapshot
        if snapshot.appLockEnabled {
            gateState = sceneState == .active
                ? .unlocked
                : .locked(message: nil)
        } else {
            gateState = .disabled
        }
    }

    func invalidate(generationID: UUID? = nil) {
        if let generationID, self.generationID != generationID {
            return
        }
        invalidateRequest()
        self.generationID = nil
        snapshot = nil
        gateState = .bootstrapping
    }

    func availabilityMessage() -> String? {
        switch client.availability() {
        case .available:
            return nil
        case let .unavailable(reason):
            return Self.userMessage(for: reason)
        }
    }

    private func invalidateRequest() {
        activeRequestID = nil
        client.cancel()
    }

    private static func userMessage(
        for failure: DeviceOwnerAuthenticationFailure
    ) -> String {
        switch failure {
        case .passcodeNotSet:
            return "请先在系统设置中启用设备密码，再使用 App Lock。"
        case .biometryNotEnrolled:
            return "设备尚未设置可用的 Face ID 或 Touch ID；你仍可使用设备密码。"
        case .biometryLockedOut:
            return "生物识别暂时不可用，请按系统提示使用设备密码。"
        case .biometryUnavailable:
            return "当前设备认证不可用，请检查系统设置。"
        case .userCancelled:
            return "你取消了认证，本地资料仍保持锁定。"
        case .systemCancelled, .appCancelled, .notInteractive:
            return "认证没有完成，请在 App 保持打开时重试。"
        case .authenticationFailed:
            return "没有通过设备认证，本地资料仍保持锁定。"
        case .unknown:
            return "设备认证没有完成，请稍后重试。"
        }
    }
}

private struct AppPrivacyCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppPrivacyCoordinator? = nil
}

extension EnvironmentValues {
    var appPrivacyCoordinator: AppPrivacyCoordinator? {
        get { self[AppPrivacyCoordinatorEnvironmentKey.self] }
        set { self[AppPrivacyCoordinatorEnvironmentKey.self] = newValue }
    }
}
