import XCTest
import VigilKit
@testable import Vigil

/// Verification-failure handling in the add / re-link flow. A provider whose
/// response Vigil can no longer read (schemaChanged) must still be savable:
/// the account watches nothing new, but removing it and being unable to
/// re-add it strands the user with no account at all.
final class AddAccountLinkFlowTests: XCTestCase {
    func testSchemaChangedVerificationOffersUnverifiedSave() {
        let resolution = AddAccountView.linkFailureResolution(
            for: AppModel.LinkError.verifyFailed(.schemaChanged)
        )
        guard case .offerUnverifiedSave(let message) = resolution else {
            return XCTFail("A drifted provider must offer Save anyway, got \(resolution)")
        }
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("save anyway"),
            "The prompt must name the action it offers: \(message)"
        )
    }

    func testNetworkVerificationStillOffersUnverifiedSave() {
        let resolution = AddAccountView.linkFailureResolution(
            for: AppModel.LinkError.verifyFailed(.network)
        )
        guard case .offerUnverifiedSave = resolution else {
            return XCTFail("Network verify failures must keep offering Save anyway")
        }
    }

    func testDeferredVerificationStillOffersUnverifiedSave() {
        let resolution = AddAccountView.linkFailureResolution(
            for: AppModel.LinkError.verificationDeferred(Date())
        )
        guard case .offerUnverifiedSave = resolution else {
            return XCTFail("Deferred verification must keep offering Save anyway")
        }
    }

    func testAuthExpiredVerificationStaysAHardFailure() {
        let resolution = AddAccountView.linkFailureResolution(
            for: AppModel.LinkError.verifyFailed(.authExpired)
        )
        guard case .fail = resolution else {
            return XCTFail("A provider-rejected credential must never be savable unverified")
        }
    }

    func testWouldReplaceMapsToReplaceConfirmation() {
        let resolution = AddAccountView.linkFailureResolution(
            for: AppModel.LinkError.wouldReplace(["Work"])
        )
        guard case .offerReplace(let labels) = resolution else {
            return XCTFail("An existing account must route to the replace confirmation")
        }
        XCTAssertEqual(labels, ["Work"])
    }

    func testUnknownErrorsFailWithTheirOwnDescription() {
        let resolution = AddAccountView.linkFailureResolution(
            for: AppModel.LinkError.persistence("disk full")
        )
        guard case .fail(let message) = resolution else {
            return XCTFail("Persistence errors are not verifiable-later states")
        }
        XCTAssertEqual(message, "disk full")
    }
}
