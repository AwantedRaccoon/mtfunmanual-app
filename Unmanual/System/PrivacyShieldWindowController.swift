import SwiftUI
import UIKit

@MainActor
final class PrivacyShieldWindowController {
    static let shared = PrivacyShieldWindowController()

    private var window: UIWindow?
    private var observationTokens: [NSObjectProtocol] = []
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        observationTokens = [
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.show()
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
        ]
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: {
                    $0.activationState != .unattached
                }) else {
            return
        }
        let shieldWindow = UIWindow(windowScene: scene)
        shieldWindow.windowLevel = .alert + 2
        shieldWindow.backgroundColor = UIColor(
            red: 15 / 255,
            green: 33 / 255,
            blue: 53 / 255,
            alpha: 1
        )
        shieldWindow.rootViewController = UIHostingController(
            rootView: RecentTasksPrivacyShield()
                .environment(AppTheme())
        )
        shieldWindow.accessibilityViewIsModal = true
        UIView.performWithoutAnimation {
            shieldWindow.isHidden = false
        }
        window = shieldWindow
    }

    private func hide() {
        guard let window else { return }
        UIView.performWithoutAnimation {
            window.isHidden = true
        }
        window.rootViewController = nil
        self.window = nil
    }
}
