import VigilKit

/// Fail-closed pairing of a stored account row and the Keychain credential
/// that would be sent on the network. Silent repair is refused: a mismatched
/// provider or key prefix is treated as local integrity failure.
enum BoundAccount {
    private static let maximumTokenBytes = 65_536
    private static let maximumAccountIDBytes = 128

    static func validated(
        account: AccountRef,
        credentials: Credentials
    ) -> (account: AccountRef, credentials: Credentials)? {
        guard credentials.providerId == account.providerId,
              ProviderRegistry.spec(for: account.providerId) != nil,
              account.key.hasPrefix("\(account.providerId):"),
              transportValuesAreSafe(credentials),
              accountIdentityMatches(account: account, credentials: credentials)
        else { return nil }
        return (account, credentials)
    }

    private static func transportValuesAreSafe(_ credentials: Credentials) -> Bool {
        guard !credentials.accessToken.isEmpty,
              credentials.accessToken.utf8.count <= maximumTokenBytes,
              !containsControlCharacters(credentials.accessToken)
        else { return false }

        if let refreshToken = credentials.refreshToken,
           refreshToken.utf8.count > maximumTokenBytes
            || containsControlCharacters(refreshToken) {
            return false
        }
        if let accountID = credentials.accountId,
           accountID.utf8.count > maximumAccountIDBytes
            || containsControlCharacters(accountID) {
            return false
        }
        return true
    }

    private static func accountIdentityMatches(
        account: AccountRef,
        credentials: Credentials
    ) -> Bool {
        guard let accountID = credentials.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !accountID.isEmpty,
            !account.key.hasPrefix("\(account.providerId):credential:")
        else {
            // Fingerprint-backed accounts deliberately keep their original
            // local key across credential rotation and targeted re-linking.
            return true
        }
        return account.key == "\(account.providerId):\(accountID)"
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .controlCharacters) != nil
    }
}
