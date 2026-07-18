import LocalAuthentication
import SwiftUI

/// Full-screen gate shown while the app is locked. Device-owner
/// authentication (biometrics with passcode fallback) so a failed Face ID
/// never strands the user.
struct AppLockView: View {
    let unlock: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var failed = false
    @State private var prompted = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Vigil is locked")
                .font(.title2.weight(.semibold))
            if failed {
                Text("Authentication didn't complete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Unlock") { authenticate() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        // Prompt only once the scene is actually frontmost — firing while
        // still backgrounded fails instantly and lands users on the "didn't
        // complete" state before they ever saw Face ID.
        .task {
            if scenePhase == .active { promptOnce() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { promptOnce() }
        }
    }

    private func promptOnce() {
        guard !prompted else { return }
        prompted = true
        authenticate()
    }

    private func authenticate() {
        failed = false
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
