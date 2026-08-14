/// Policy for the device-owner lock. A failed or unavailable evaluation must
/// not reveal accounts. The user can still delete and reinstall the app if a
/// device passcode is later removed.
enum AppLockAuthentication {
    static var unlocksWhenPolicyUnavailable: Bool { false }
}
