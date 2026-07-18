import SwiftUI

/// Quotes docs/privacy.md — the model is one sentence, so the page is short.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your credentials and usage data never leave your devices.")
                    .font(.title3.weight(.semibold))

                bullet("There is no Vigil server, no Vigil account, no cloud sync, no analytics, no crash reporting that phones home.")
                bullet("Credentials exist in exactly three places, all yours: the provider's own files on your computer, transiently in vigil-link and the QR code on your screen while linking, and this device's Keychain (ThisDeviceOnly — not even iCloud Keychain sync).")
                bullet("The app's only network traffic is direct calls to the providers you linked, using your own credentials — the same calls those vendors' own tools make.")
                bullet("The vigil-link CLI is stateless: it writes nothing to disk, ever. Audit it — it's small on purpose.")
                bullet("Removing an account deletes its Keychain items immediately.")

                Text("Because Keychain items are ThisDeviceOnly, each device is linked with its own scan. That is a feature: no credential ever transits a sync service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Privacy")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
        .font(.callout)
    }
}
