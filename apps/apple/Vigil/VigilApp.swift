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

enum AppPrivacyLaunchConfiguration {
    /// UI automation can present the unsigned-storage alert while SwiftUI
    /// still reports an inactive scene on older simulator runtimes. Keep the
    /// privacy cover deterministic for those tests without weakening release
    /// behavior.
    static func forcesActiveSceneForUITesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        environment["VIGIL_UI_TEST_FORCE_ACTIVE"] == "1"
        #else
        false
        #endif
    }
}

enum AppStorageNoticeLaunchConfiguration {
    /// Unsigned UI-test processes cannot access the production App Group and
    /// may queue several expected storage notices. Route and lock automation
    /// opts out of those notices. Release builds never honor this override.
    static func suppressesForUITesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        environment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] == "1"
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
    private let forcesActiveSceneForUITesting: Bool

    init() {
        let model = AppModel()
        let holdsLockForUITesting = AppLockLaunchConfiguration.holdsLockForUITesting()
        let forcesActiveSceneForUITesting =
            AppPrivacyLaunchConfiguration.forcesActiveSceneForUITesting()
        _model = State(initialValue: model)
        _locked = State(initialValue: model.lockEnabled || holdsLockForUITesting)
        self.holdsLockForUITesting = holdsLockForUITesting
        self.forcesActiveSceneForUITesting = forcesActiveSceneForUITesting
        BackgroundRefresh.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            let presentationScenePhase: ScenePhase = forcesActiveSceneForUITesting
                ? .active
                : scenePhase
            let showsPrivacyCover = AppPrivacyPolicy.showsPrivacyCover(
                for: presentationScenePhase
            )
            let hidesProtectedContent = AppPrivacyPolicy.hidesProtectedContent(
                locked: locked,
                scenePhase: presentationScenePhase
            )

            ZStack {
                if model.hasLoadedFromDisk || model.isDemo {
                    RootView()
                        .disabled(hidesProtectedContent)
                        .allowsHitTesting(!hidesProtectedContent)
                        .accessibilityHidden(hidesProtectedContent)
                        .opacity(hidesProtectedContent ? 0 : 1)
                } else {
                    // Pre-load launch frame. The disk load is deferred past
                    // UIApplicationMain (0xdead10cc), and an unloaded model
                    // must never present as an empty account list.
                    Color.black.ignoresSafeArea()
                }

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
            .task { model.ensureLoadedFromDisk() }
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
