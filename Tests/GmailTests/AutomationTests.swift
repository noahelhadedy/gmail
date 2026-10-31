import XCTest
@testable import Gmail

final class AutomationCommandTests: XCTestCase {
    func testAddAccountWithLoginHint() {
        let url = URL(string: "gmailmenubar://add-account?login_hint=noah%2Bx@example.com")!
        XCTAssertEqual(AutomationCommand(url: url), .addAccount(loginHint: "noah+x@example.com"))
    }

    func testAddAccountWithoutLoginHint() {
        XCTAssertEqual(AutomationCommand(url: URL(string: "gmailmenubar://add-account")!), .addAccount(loginHint: nil))
    }

    func testAddAccountEmptyLoginHintIsNil() {
        let url = URL(string: "gmailmenubar://add-account?login_hint=")!
        XCTAssertEqual(AutomationCommand(url: url), .addAccount(loginHint: nil))
    }

    func testStatus() {
        XCTAssertEqual(AutomationCommand(url: URL(string: "gmailmenubar://status")!), .status)
        XCTAssertEqual(AutomationCommand(url: URL(string: "GMAILMENUBAR://Status")!), .status)
    }

    func testUnknownCommand() {
        XCTAssertNil(AutomationCommand(url: URL(string: "gmailmenubar://delete-everything")!))
        XCTAssertNil(AutomationCommand(url: URL(string: "gmailmenubar://")!))
    }

    func testOtherSchemeIsIgnored() {
        XCTAssertNil(AutomationCommand(url: URL(string: "com.googleusercontent.apps.123:/oauth2redirect")!))
        XCTAssertNil(AutomationCommand(url: URL(string: "https://status")!))
    }
}

@MainActor
final class AutomationStatusTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeState() -> AppState {
        let state = AppState()
        let ok = AccountState(email: "a@example.com", colorIndex: 0)
        ok.unreadCount = 3
        let expired = AccountState(email: "b@example.com", colorIndex: 1, authState: .needsReauthorization)
        let failing = AccountState(email: "c@example.com", colorIndex: 2)
        failing.lastError = .network(.offline)
        state.accounts = [ok, expired, failing]
        return state
    }

    func testAccountStates() {
        let writer = AutomationStatusWriter(appState: makeState(), fileURL: tempDir.appendingPathComponent("s.json"))
        let accounts = writer.snapshot().accounts
        XCTAssertEqual(accounts.map(\.state), [.ok, .needsReauth, .error])
        XCTAssertEqual(accounts[0].unreadCount, 3)
        XCTAssertNil(accounts[0].lastError)
        XCTAssertNotNil(accounts[2].lastError)
    }

    func testEncodedJSONHasNoTokenFields() throws {
        let writer = AutomationStatusWriter(appState: makeState(), fileURL: tempDir.appendingPathComponent("s.json"))
        writer.recordAddAccount(email: "a@example.com", loginHint: "a@example.com", error: nil)
        let data = try AutomationStatus.encoder().encode(writer.snapshot())
        let json = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["token", "secret", "refresh", "access"] {
            XCTAssertFalse(json.contains(forbidden), "status JSON contains \(forbidden)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["updatedAt", "addAccountInProgress", "accounts", "lastAddAccount"])
        let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(account.keys), ["email", "state", "unreadCount"])
        XCTAssertEqual(account["state"] as? String, "ok")
    }

    func testWriteCreatesPrivateFileAndKeepsLastResultAcrossRelaunch() throws {
        let file = tempDir.appendingPathComponent("s.json")
        let writer = AutomationStatusWriter(appState: makeState(), fileURL: file)
        writer.recordAddAccount(email: nil, loginHint: "x@example.com", error: AppError.auth(.notSignedIn))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let decoded = try AutomationStatus.decoder().decode(AutomationStatus.self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded.lastAddAccount?.ok, false)
        XCTAssertEqual(decoded.lastAddAccount?.loginHint, "x@example.com")
        XCTAssertNotNil(decoded.lastAddAccount?.error)

        let relaunched = AutomationStatusWriter(appState: AppState(), fileURL: file)
        XCTAssertEqual(relaunched.lastAddAccount, decoded.lastAddAccount)
    }
}
