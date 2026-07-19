import SwiftUI

/// Summarizes docs/privacy.md in the shipped app.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Vigil does not collect your credentials or usage data.")
                    .font(.title3.weight(.semibold))

                bullet("There is no Vigil server, no Vigil account, no cloud sync, no analytics, no crash reporting that phones home.")
                bullet("Credentials may exist in a provider's files on your computer, transiently in vigil-link and its plaintext QR code while linking, and in this device's ThisDeviceOnly Keychain.")
                bullet("The app sends credentials and usage requests directly to the providers you activate. Vigil does not receive those requests or responses.")
                bullet("vigil-link never writes credentials or usage values. It stores only poll timestamps and 429 counters in your user cache so repeated commands respect provider limits.")
                bullet("Removing an account deletes its Keychain item and local usage metadata. Vigil shows an error if any deletion fails.")

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
