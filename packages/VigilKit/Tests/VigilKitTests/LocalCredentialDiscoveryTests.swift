import Foundation
import XCTest
@testable import VigilKit

final class LocalCredentialDiscoveryTests: XCTestCase {
    func testParsesClaudeCredentialsFileBlob() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-test",
            "refreshToken": "sk-ant-ort-test",
            "expiresAt": 2000000000000,
            "subscriptionType": "max"
          }
        }
        """
        let credentials = try XCTUnwrap(LocalCredentialDiscovery.parseClaudeCredentials(json: json))
        XCTAssertEqual(credentials.providerId, "claude")
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat-test")
        XCTAssertEqual(credentials.refreshToken, "sk-ant-ort-test")
        XCTAssertEqual(credentials.plan, "max")
        XCTAssertEqual(credentials.label, "Claude (max)")
        XCTAssertEqual(credentials.source, LocalCredentialDiscovery.fileSource)
        let expiresAt = try XCTUnwrap(credentials.expiresAt)
        XCTAssertEqual(
            expiresAt.timeIntervalSince1970,
            2_000_000_000,
            accuracy: 0.001,
            "Claude Code stores expiresAt in epoch milliseconds"
        )
    }

    func testParsesClaudeRootLevelAccessToken() throws {
        let json = #"{"accessToken":"plain-token"}"#
        let credentials = try XCTUnwrap(LocalCredentialDiscovery.parseClaudeCredentials(json: json))
        XCTAssertEqual(credentials.accessToken, "plain-token")
        XCTAssertEqual(credentials.label, "Claude")
        XCTAssertNil(credentials.refreshToken)
    }

    func testRejectsEmptyClaudeBlob() {
        XCTAssertNil(LocalCredentialDiscovery.parseClaudeCredentials(json: #"{"claudeAiOauth":{}}"#))
        XCTAssertNil(LocalCredentialDiscovery.parseClaudeCredentials(json: "not-json"))
    }

    func testParsesCodexAuthJson() throws {
        // Minimal JWT: header.payload.sig with chatgpt_account_id + email claims.
        let payload = Data(#"{"chatgpt_account_id":"acct-9","chatgpt_plan_type":"plus","email":"a@b.c","exp":2000000000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let idToken = "e30.\(payload).sig"
        let accessPayload = Data(#"{"exp":2000000000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let accessToken = "e30.\(accessPayload).sig"

        let json = """
        {
          "tokens": {
            "access_token": "\(accessToken)",
            "refresh_token": "rt-1",
            "id_token": "\(idToken)",
            "account_id": "acct-9"
          }
        }
        """
        let credentials = try XCTUnwrap(LocalCredentialDiscovery.parseCodexCredentials(json: json))
        XCTAssertEqual(credentials.providerId, "codex")
        XCTAssertEqual(credentials.accessToken, accessToken)
        XCTAssertEqual(credentials.refreshToken, "rt-1")
        XCTAssertEqual(credentials.accountId, "acct-9")
        XCTAssertEqual(credentials.plan, "plus")
        XCTAssertEqual(credentials.source, LocalCredentialDiscovery.fileSource)
        XCTAssertTrue(credentials.label?.contains("plus") == true)
        XCTAssertTrue(credentials.label?.contains("a@b.c") == true)
    }

    func testCodexRequiresAccountId() {
        let json = #"{"tokens":{"access_token":"e30.e30.sig"}}"#
        XCTAssertNil(LocalCredentialDiscovery.parseCodexCredentials(json: json))
    }

    func testDefaultPaths() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        XCTAssertEqual(
            LocalCredentialDiscovery.defaultClaudeCredentialsURL(home: home).path,
            "/Users/demo/.claude/.credentials.json"
        )
        XCTAssertEqual(
            LocalCredentialDiscovery.defaultCodexAuthURL(home: home, environment: [:]).path,
            "/Users/demo/.codex/auth.json"
        )
        XCTAssertEqual(
            LocalCredentialDiscovery.defaultCodexAuthURL(
                home: home,
                environment: ["CODEX_HOME": "/tmp/codex-home"]
            ).path,
            "/tmp/codex-home/auth.json"
        )
    }

    func testLoadFromDefaultFilesRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilLocalDiscovery-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try Data(#"{"claudeAiOauth":{"accessToken":"claude-at","subscriptionType":"pro"}}"#.utf8)
            .write(to: claudeDir.appendingPathComponent(".credentials.json"))

        let payload = Data(#"{"chatgpt_account_id":"acct-1"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let idToken = "e30.\(payload).sig"
        let codexJSON = """
        {"tokens":{"access_token":"codex-at","id_token":"\(idToken)","account_id":"acct-1"}}
        """
        try Data(codexJSON.utf8).write(to: codexDir.appendingPathComponent("auth.json"))

        let claude = try XCTUnwrap(LocalCredentialDiscovery.loadClaudeFromDefaultFile(home: home))
        XCTAssertEqual(claude.credentials.accessToken, "claude-at")
        XCTAssertEqual(claude.location, .file)

        let codex = try XCTUnwrap(LocalCredentialDiscovery.loadCodexFromDefaultFile(home: home))
        XCTAssertEqual(codex.credentials.accessToken, "codex-at")
        XCTAssertEqual(codex.credentials.accountId, "acct-1")
    }
}
