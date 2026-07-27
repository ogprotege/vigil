import LocalAuthentication
import SwiftUI

/// Full-screen gate shown while the app is locked. Device-owner
/// authentication (biometrics with passcode fallback) so a failed Face ID
/// never strands the user.
struct AppLockView: View {
    let unlock: () -> Void
    let automaticallyAuthenticates: Bool
    let authenticationOverride: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var failed = false
    @State private var prompted = false

    init(
        automaticallyAuthenticates: Bool = true,
        authenticationOverride: (() -> Void)? = nil,
        unlock: @escaping () -> Void
    ) {
        self.automaticallyAuthenticates = automaticallyAuthenticates
        self.authenticationOverride = authenticationOverride
        self.unlock = unlock
    }

    var body: some View {
        ZStack {
            VigilPalette.canvas
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(VigilPalette.inkMuted)
                    .accessibilityHidden(true)
                Text("Vigil is locked")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if failed {
                    Text("Authentication didn't complete.")
                        .font(.callout)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
                Button(action: authenticate) {
                    Text("Unlock")
                        .frame(minWidth: 120, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(VigilPalette.signal)
                .accessibilityIdentifier("vigil.lock.unlock")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vigil.lock")
        .accessibilityAddTraits(.isModal)
        // Prompt only once the scene is actually frontmost — firing while
        // still backgrounded fails instantly and lands users on the "didn't
        // complete" state before they ever saw Face ID.
        .task {
            if automaticallyAuthenticates, scenePhase == .active { promptOnce() }
        }
        .onChange(of: scenePhase) { _, phase in
            if automaticallyAuthenticates, phase == .active { promptOnce() }
        }
    }

    private func promptOnce() {
        guard !prompted else { return }
        prompted = true
        authenticate()
    }

    private func authenticate() {
        failed = false
        if let authenticationOverride {
            authenticationOverride()
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set at all — locking is meaningless; let them in.
            unlock()
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock Vigil to see your accounts and usage."
        ) { success, _ in
            Task { @MainActor in
                if success { unlock() } else { failed = true }
            }
        }
    }
}

/// Opaque scene-phase cover captured by iOS for inactive and app-switcher
/// snapshots. It intentionally exposes no provider or account information.
struct AppSwitcherPrivacyCover: View {
    var body: some View {
        ZStack {
            VigilPalette.canvas
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                Text("Vigil")
                    .font(.title2.weight(.semibold))
            }
            .foregroundStyle(VigilPalette.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
