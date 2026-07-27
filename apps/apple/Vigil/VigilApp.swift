import SwiftUI
import VigilKit
import BackgroundTasks

enum AppPrivacyPolicy {
    static func showsPrivacyCover(for scenePhase: ScenePhase) -> Bool {
        switch scenePhase {
        case .active:
            false
        case .inactive, .background:
            true
        @unknown default:
            true
        }
    }

    static func hidesProtectedContent(
        locked: Bool,
        scenePhase: ScenePhase
    ) -> Bool {
        locked || showsPrivacyCover(for: scenePhase)
    }
}

enum AppLockLaunchConfiguration {
    /// Deterministic lock state for accessibility UI tests. Release builds
    /// never honor process-environment overrides.
    static func holdsLockForUITesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        environment["VIGIL_UI_TEST_LOCKED"] == "1"
        #else
        false
        #endif
    }
}

@main
struct VigilApp: App {
    @State private var model: AppModel
    @State private var locked: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let holdsLockForUITesting: Bool

    init() {
        let model = AppModel()
        let holdsLockForUITesting = AppLockLaunchConfiguration.holdsLockForUITesting()
        _model = State(initialValue: model)
        _locked = State(initialValue: model.lockEnabled || holdsLockForUITesting)
        self.holdsLockForUITesting = holdsLockForUITesting
        BackgroundRefresh.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            let showsPrivacyCover = AppPrivacyPolicy.showsPrivacyCover(for: scenePhase)
            let hidesProtectedContent = AppPrivacyPolicy.hidesProtectedContent(
                locked: locked,
                scenePhase: scenePhase
            )

            ZStack {
                RootView()
                    .disabled(hidesProtectedContent)
                    .allowsHitTesting(!hidesProtectedContent)
                    .accessibilityHidden(hidesProtectedContent)
                    .opacity(hidesProtectedContent ? 0 : 1)

                if locked {
                    AppLockView(
                        automaticallyAuthenticates: !holdsLockForUITesting,
                        authenticationOverride: holdsLockForUITesting
                            ? { locked = false }
                            : nil
                    ) {
                        locked = false
                    }
                    .zIndex(1)
                }

                if showsPrivacyCover {
                    AppSwitcherPrivacyCover()
                        .zIndex(2)
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(to: phase)
                switch phase {
                case .background:
                    if model.lockEnabled { locked = true }
                    BackgroundRefresh.schedule()
                default:
                    break
                }
            }
        }
    }
}
