import SwiftUI
import VigilKit
#if os(iOS)
import BackgroundTasks
#endif

@main
struct VigilApp: App {
    @State private var model: AppModel
    @State private var locked: Bool
    @State private var deepLink: DeepLinkState?
    @Environment(\.scenePhase) private var scenePhase

    enum DeepLinkState {
        case failed(String)
        case confirmAdd(LinkPayload, [String])
        case confirmUnverified(LinkPayload, String)
        case confirmReplace(LinkPayload, [String])
    }

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _locked = State(initialValue: model.lockEnabled)
        #if os(iOS)
        BackgroundRefresh.register(model: model)
        #endif
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
            .onOpenURL { url in
                handleDeepLink(url)
            }
            .alert(
                deepLinkAlertTitle,
                isPresented: .init(
                    get: { deepLink != nil },
                    set: { if !$0 { deepLink = nil } }
                )
            ) {
                switch deepLink {
                case .confirmAdd(let payload, _):
                    Button("Add") { add(payload, allowUnverified: false, allowReplace: false) }
                    Button("Cancel", role: .cancel) {}
                case .confirmUnverified(let payload, _):
                    Button("Save anyway") { add(payload, allowUnverified: true, allowReplace: true) }
                    Button("Cancel", role: .cancel) {}
                case .confirmReplace(let payload, _):
                    Button("Replace") { add(payload, allowUnverified: false, allowReplace: true) }
                    Button("Cancel", role: .cancel) {}
                default:
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(deepLinkAlertMessage)
            }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(to: phase)
                switch phase {
                case .background:
                    if model.lockEnabled { locked = true }
                    #if os(iOS)
                    BackgroundRefresh.schedule()
                    #endif
                default:
                    break
                }
            }
        }

        #if os(macOS)
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(model)
            .preferredColorScheme(.dark)
        }

        // M7 — the always-fresh surface: percentages in the menu bar while no
        // window is open, refreshed by the model's timer (ledger-gated).
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
                .preferredColorScheme(.dark)
        } label: {
            Text(model.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    private var deepLinkAlertTitle: String {
        switch deepLink {
        case .confirmAdd: return "Add account?"
        case .confirmUnverified: return "Couldn't verify"
        case .confirmReplace: return "Replace account?"
        default: return "Link code"
        }
    }

    private var deepLinkAlertMessage: String {
        switch deepLink {
        case .failed(let message): return message
        case .confirmAdd(_, let labels):
            return "This link adds \(labels.joined(separator: ", ")). Continue only if you just created it on your own computer."
        case .confirmUnverified(_, let message):
            return message
        case .confirmReplace(_, let labels):
            return "This replaces the already-linked \(labels.joined(separator: ", "))."
        case nil: return ""
        }
    }

    /// Stock-camera deep link: a single-chunk vigil1 envelope IS a URL with
    /// the (registered) `vigil1:` scheme — scanning with the iPhone camera
    /// opens Vigil directly with the payload. Because ANY app or webpage can
    /// invoke a registered scheme, a URL-delivered payload never verifies or
    /// persists anything until the user explicitly confirms the add — unlike
    /// the in-app scanner, which the user opened on purpose.
    private func handleDeepLink(_ url: URL) {
        do {
            let payload = try QRDecoder.decodePayload([url.absoluteString], now: Date())
            let labels = payload.accounts.map(\.label)
            deepLink = .confirmAdd(payload, labels)
        } catch QRDecodeError.incomplete {
            deepLink = .failed("That's one code of a multi-part link — open Vigil and use Add Account → Scan to capture all of them.")
        } catch QRDecodeError.expired {
            deepLink = .failed("This link code expired (older than 10 minutes). Create a fresh code on your computer and try again.")
        } catch {
            deepLink = .failed("Couldn't read that link code.")
        }
    }

    private func add(_ payload: LinkPayload, allowUnverified: Bool, allowReplace: Bool) {
        Task {
            do {
                try await model.addAccounts(from: payload, allowUnverified: allowUnverified, allowReplace: allowReplace)
            } catch AppModel.LinkError.verifyFailed(.network) {
                deepLink = .confirmUnverified(
                    payload,
                    "Network problem while verifying. Save and verify later?"
                )
            } catch AppModel.LinkError.verificationDeferred(_) {
                deepLink = .confirmUnverified(
                    payload,
                    "Vigil's polling safety cooldown deferred this check. Save now and verify on the next allowed refresh?"
                )
            } catch AppModel.LinkError.wouldReplace(let labels) {
                deepLink = .confirmReplace(payload, labels)
            } catch {
                deepLink = .failed(error.localizedDescription)
            }
        }
    }
}
