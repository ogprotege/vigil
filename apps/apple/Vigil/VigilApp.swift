import SwiftUI
import VigilKit
import BackgroundTasks

@main
struct VigilApp: App {
    @State private var model: AppModel
    @State private var locked: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _locked = State(initialValue: model.lockEnabled)
        BackgroundRefresh.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
            .environment(model)
            .preferredColorScheme(.dark)
            .overlay {
                if locked {
                    AppLockView { locked = false }
                }
            }
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
