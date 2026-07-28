import Foundation
import XCTest
import VigilKit
@testable import Vigil

@MainActor
final class RefreshReportTests: XCTestCase {
    func testRefreshReportMessageWhenFullyDeferred() {
        let next = Date().addingTimeInterval(180)
        let report = AppModel.RefreshReport(
            fetched: 0,
            deferred: 2,
            failed: 0,
            nextAllowedAt: next
        )
        XCTAssertTrue(report.userMessage.contains("Next safe refresh"))
        XCTAssertFalse(report.didFetchAnything)
    }

    func testRefreshReportMessageWhenAllFetched() {
        let report = AppModel.RefreshReport(
            fetched: 3,
            deferred: 0,
            failed: 0,
            nextAllowedAt: nil
        )
        XCTAssertEqual(report.userMessage, "Updated 3 accounts from providers.")
        XCTAssertTrue(report.didFetchAnything)
    }

    func testRefreshReportMessageWhenMixed() {
        let report = AppModel.RefreshReport(
            fetched: 1,
            deferred: 1,
            failed: 1,
            nextAllowedAt: nil
        )
        XCTAssertTrue(report.userMessage.contains("Updated 1"))
        XCTAssertTrue(report.userMessage.contains("rate limit"))
        XCTAssertTrue(report.userMessage.contains("failed"))
    }
}
