import XCTest
@testable import Gmail

@MainActor
final class AccountManagerTests: XCTestCase {
    private var appState: AppState!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: KeychainService!
    private var authorizer: MockAuthorizer!
    private var api: MockAPI!
    private var manager: AccountManager!

    override func setUp() async throws {
        try await super.setUp()
        appState = AppState()
        suiteName = "manager.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychain = KeychainService(service: "com.pezy.gmail.tests.\(UUID().uuidString)")
        authorizer = MockAuthorizer()
        api = MockAPI()
        manager = makeManager(authorizer: authorizer)
    }

    override func tearDown() async throws {
        for email in ["a@example.com", "b@example.com", KeychainService.pendingAccount] {
            try? keychain.delete(account: email)
        }
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testAddAccountStoresTokensUnderEmailAndPolls() async throws {
        signInAs("a@example.com", historyId: "10")
        api.inboxUnreadCountResult = .success(4)

        let email = try await manager.addAccount()

        XCTAssertEqual(email, "a@example.com")
        XCTAssertEqual(appState.accounts.map(\.email), ["a@example.com"])
        XCTAssertEqual(appState.totalUnreadCount, 4)
        XCTAssertNotNil(try keychain.load(account: "a@example.com"))
        XCTAssertNil(try keychain.load(account: KeychainService.pendingAccount))
        XCTAssertEqual(AccountStore(defaults: defaults).load().map(\.email), ["a@example.com"])
    }

    func testExternalBrowserModeReachesAuthorizerAndReportsChanges() async throws {
        signInAs("a@example.com", historyId: "10")
        var changes = 0
        manager.onAccountsChanged = { changes += 1 }

        let email = try await manager.addAccount(mode: .externalBrowser(loginHint: "a@example.com"))

        XCTAssertEqual(email, "a@example.com")
        XCTAssertEqual(authorizer.lastSignInMode, .externalBrowser(loginHint: "a@example.com"))
        XCTAssertGreaterThan(changes, 0, "a poll tick should refresh the status file")
    }

    func testDefaultAddAccountUsesInAppSheet() async throws {
        signInAs("a@example.com", historyId: "10")
        _ = try await manager.addAccount()
        XCTAssertEqual(authorizer.lastSignInMode, .inApp)
    }

    func testTwoAccountsAreIndependentAndTotalsAdd() async throws {
        signInAs("a@example.com", historyId: "10")
        api.inboxUnreadCountResult = .success(4)
        try await manager.addAccount()
        signInAs("b@example.com", historyId: "20")
        api.inboxUnreadCountResult = .success(6)
        try await manager.addAccount()

        XCTAssertEqual(appState.accounts.map(\.email), ["a@example.com", "b@example.com"])
        XCTAssertEqual(appState.accounts.map(\.colorIndex), [0, 1])
        XCTAssertEqual(appState.totalUnreadCount, 10)
        XCTAssertEqual(manager.coordinators.count, 2)
        XCTAssertEqual(defaults.string(forKey: PollingCoordinator.historyIdKey(for: "a@example.com")), "10")
        XCTAssertEqual(defaults.string(forKey: PollingCoordinator.historyIdKey(for: "b@example.com")), "20")
    }

    func testReAddingSameAccountReplacesTokensWithoutDuplicating() async throws {
        signInAs("a@example.com", historyId: "10")
        try await manager.addAccount()
        appState.accounts[0].authState = .needsReauthorization

        signInAs("a@example.com", historyId: "11", access: "new-token")
        try await manager.addAccount()

        XCTAssertEqual(appState.accounts.count, 1)
        XCTAssertEqual(appState.accounts[0].authState, .signedIn(email: "a@example.com"))
        let data = try XCTUnwrap(try keychain.load(account: "a@example.com"))
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: data).accessToken, "new-token")
    }

    func testRemoveAccountClearsEverythingForThatAccountOnly() async throws {
        signInAs("a@example.com", historyId: "10")
        try await manager.addAccount()
        signInAs("b@example.com", historyId: "20")
        try await manager.addAccount()

        await manager.removeAccount(email: "a@example.com")

        XCTAssertEqual(appState.accounts.map(\.email), ["b@example.com"])
        XCTAssertNil(try keychain.load(account: "a@example.com"))
        XCTAssertNotNil(try keychain.load(account: "b@example.com"))
        XCTAssertNil(defaults.string(forKey: PollingCoordinator.historyIdKey(for: "a@example.com")))
        XCTAssertEqual(AccountStore(defaults: defaults).load().map(\.email), ["b@example.com"])
        XCTAssertEqual(authorizer.revokeCallCount, 1)
    }

    func testRestoreMarksAccountWithoutTokensAsNeedingSignIn() async throws {
        signInAs("a@example.com", historyId: "10")
        try await manager.addAccount()
        AccountStore(defaults: defaults).add(email: "b@example.com")  // listed, but no Keychain entry

        let relaunched = AppState()
        let fresh = makeManager(authorizer: authorizer, appState: relaunched)
        await fresh.restoreAll()

        XCTAssertEqual(relaunched.accounts.map(\.email), ["a@example.com", "b@example.com"])
        XCTAssertEqual(relaunched.account(for: "a@example.com")?.authState, .signedIn(email: "a@example.com"))
        XCTAssertEqual(relaunched.account(for: "b@example.com")?.authState, .needsReauthorization)
        XCTAssertEqual(relaunched.aggregateAuthState, .needsReauthorization)
    }

    func testOneAccountFailingDoesNotBreakTheOther() async throws {
        signInAs("a@example.com", historyId: "10")
        try await manager.addAccount()
        signInAs("b@example.com", historyId: "20")
        api.inboxUnreadCountResult = .success(5)
        try await manager.addAccount()

        // a@'s history call fails with a server error; b@ is unaffected because each
        // coordinator catches its own errors.
        api.historyResult = .failure(AppError.api(.serverError(status: 503)))
        await manager.refreshAll()

        let a = try XCTUnwrap(appState.account(for: "a@example.com"))
        let b = try XCTUnwrap(appState.account(for: "b@example.com"))
        XCTAssertEqual(a.lastError, .api(.serverError(status: 503)))
        XCTAssertEqual(b.lastError, .api(.serverError(status: 503)))  // same mock for both
        XCTAssertEqual(a.authState, .signedIn(email: "a@example.com"))
        XCTAssertEqual(b.authState, .signedIn(email: "b@example.com"))

        // Revoke only a@'s tokens: a@ needs sign-in, b@ keeps polling fine.
        try keychain.delete(account: "a@example.com")
        let relaunched = AppState()
        let fresh = makeManager(authorizer: authorizer, appState: relaunched)
        api.historyResult = .success(HistoryResponse(historyId: "21", changes: []))
        api.inboxUnreadCountResult = .success(7)
        await fresh.restoreAll()

        XCTAssertEqual(relaunched.account(for: "a@example.com")?.authState, .needsReauthorization)
        XCTAssertEqual(relaunched.account(for: "b@example.com")?.authState, .signedIn(email: "b@example.com"))
        XCTAssertEqual(relaunched.account(for: "b@example.com")?.unreadCount, 7)
        XCTAssertEqual(relaunched.totalUnreadCount, 7)
    }

    func testAddAccountWithoutClientIDFails() async {
        let unconfigured = makeManager(authorizer: nil)
        XCTAssertFalse(appState.isConfigured)
        do {
            try await unconfigured.addAccount()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(appState.accounts.count, 0)
        }
    }

    func testNetworkChangeUpdatesSharedConnectionState() async {
        await manager.networkChanged(to: .offline)
        XCTAssertEqual(appState.connectionState, .offline)
    }

    func testIntervalPropagatesToEveryCoordinator() async throws {
        signInAs("a@example.com", historyId: "10")
        try await manager.addAccount()
        signInAs("b@example.com", historyId: "20")
        try await manager.addAccount()

        manager.interval = 300

        XCTAssertEqual(manager.coordinators.values.map(\.interval), [300, 300])
    }

    private func signInAs(_ email: String, historyId: String, access: String = "atoken") {
        authorizer.initialResult = .success(AuthSession(
            accessToken: access,
            refreshToken: "rtoken",
            idToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            email: nil
        ))
        api.profileResult = .success(GmailProfile(emailAddress: email, historyId: historyId, messagesTotal: 0))
        api.listResult = .success(MessageListResponse(messageIds: [], resultSizeEstimate: 0))
    }

    private func makeManager(authorizer: AuthorizationPerforming?, appState: AppState? = nil) -> AccountManager {
        AccountManager(
            appState: appState ?? self.appState,
            store: AccountStore(defaults: defaults),
            keychain: keychain,
            authorizer: authorizer,
            api: api,
            notifier: nil,
            userDefaults: defaults,
            makeScheduler: { MockScheduler() }
        )
    }
}
