import VigilKit

/// Fail-closed pairing of a stored account row and the Keychain credential
/// that would be sent on the network. Silent repair is refused: a mismatched
/// provider or key prefix is treated as local integrity failure.
enum BoundAccount {
    static func validated(
        account: AccountRef,
        credentials: Credentials
    ) -> (account: AccountRef, credentials: Credentials)? {
        guard credentials.providerId == account.providerId,
              ProviderRegistry.spec(for: account.providerId) != nil,
              account.key.hasPrefix("\(account.providerId):")
        else { return nil }
        return (account, credentials)
    }
}
