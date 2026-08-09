import SwiftUI

/// Summarizes docs/privacy.md in the shipped app.
struct PrivacyView: View {
    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    VStack(alignment: .leading, spacing: 6) {
                        VigilEyebrow(text: "Privacy")
                        Text("Your watch stays yours.")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(VigilPalette.ink)
                        Text("Vigil does not collect your credentials or usage data.")
                            .font(.subheadline)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        privacyPoint(
                            symbol: "server.rack",
                            title: "No Vigil server",
                            text: "No account, cloud sync, analytics, or crash reporting phones home."
                        )
                        privacyPoint(
                            symbol: "key.fill",
                            title: "Device-only credentials",
                            text: "Credentials live in this device's ThisDeviceOnly Keychain. Each device links separately."
                        )
                        privacyPoint(
                            symbol: "arrow.left.arrow.right",
                            title: "Direct provider requests",
                            text: "The app sends credentials and usage requests only to providers you activate."
                        )
                        privacyPoint(
                            symbol: "trash",
                            title: "Visible deletion",
                            text: "Removing an account deletes its Keychain item and local usage metadata. Vigil reports any failed deletion."
                        )

                        Link(destination: VigilLinks.privacyPolicyURL) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(VigilPalette.signal)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        VigilPalette.signal.opacity(0.11),
                                        in: RoundedRectangle(cornerRadius: 11)
                                    )
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Read the full privacy policy")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(VigilPalette.ink)
                                    Text("Data handling, provider boundaries, retention, and deletion")
                                        .font(.caption)
                                        .foregroundStyle(VigilPalette.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(VigilPalette.inkFaint)
                                    .accessibilityHidden(true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .vigilInsetSurface()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("vigil.privacy.fullPolicy")
                    }
                    .vigilCard(padding: VigilSpacing.medium)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyPoint(
        symbol: String,
        title: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(VigilPalette.signal)
                .frame(width: 36, height: 36)
                .background(
                    VigilPalette.signal.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilInsetSurface()
    }
}
