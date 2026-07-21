#if os(macOS)
import SwiftUI

/// Menu-bar placeholder shown while the app lock is engaged.
///
/// The lock overlay lives on the WindowGroup, but the menu bar is a sibling
/// scene rendering the same account labels (the Codex label carries the
/// sign-in email), usage values and a working Refresh. Settings promises to
/// "Lock Vigil whenever it returns to the foreground" without qualification,
/// so this surface stays closed until the main window is unlocked.
struct MenuBarLockedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Vigil is locked", systemImage: "lock.fill")
                .font(.headline)
            Text("Open the Vigil window and authenticate to see your usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
