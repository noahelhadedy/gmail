import XCTest
@testable import Gmail

final class MockZohoAPI: ZohoAPIClienting, @unchecked Sendable {
    var account = ZohoAccountInfo(
        accountId: "42",
        primaryEmail: "noah@designbookmark.com",
        addresses: ["hello@designbookmark.com", "noah@designbookmark.com"]
    )
    var accountResult: Result<ZohoAccountInfo, Error>?
    var listResult: Result<[EmailMessage], Error> = .success([])
    var markResult: Result<Void, Error> = .success(())
    var markedIds: [String] = []
    var listCallCount = 0

    func getAccount(accessToken: String) async throws -> ZohoAccountInfo {
        try (accountResult ?? .success(account)).get()
    }

    func inboxFolderId(accessToken: String, accountId: String) async throws -> String { "INBOX1" }

    func listUnread(accessToken: String, accountId: String, folderId: String, limit: Int) async throws -> [EmailMessage] {
        listCallCount += 1
        return try listResult.get()
    }

    func markAsRead(accessToken: String, accountId: String, messageId: String) async throws {
        markedIds.append(messageId)
        try markResult.get()
        // Like Zoho: a read message is no longer in the unread list.
        if case .success(let messages) = listResult {
            listResult = .success(messages.filter { $0.id != messageId })
        }
    }
}

private final class URLRecordingNotifier: PollingNotifying, @unchecked Sendable {
    var notified: [EmailMessage] = []
    var urls: [URL] = []
    var gmailNotified: [EmailMessage] = []

    func notifyNewMessages(_ messages: [EmailMessage], account: String) async {
        gmailNotified.append(contentsOf: messages)
    }

    func notifyNewMessages(_ messages: [EmailMessage], account: String, openURL: @escaping @Sendable (EmailMessage) -> URL) async {
        notified.append(contentsOf: messages)
        urls.append(contentsOf: messages.map(openURL))
    }
}

private func zohoMessage(_ id: String, minutesAgo: Double = 1) -> EmailMessage {
    EmailMessage(
        id: id, threadId: id, from: "Customer <c@example.com>", subject: "Subject \(id)",
        internalDate: Date().addingTimeInterval(-minutesAgo * 60), snippet: "snippet"
    )
}

@MainActor
final class ZohoPollingCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: KeychainService!
    private var authorizer: MockAuthorizer!
    private var api: MockZohoAPI!
    private var notifier: URLRecordingNotifier!
    private var account: AccountState!
    private var coordinator: ZohoPollingCoordinator!

    override func setUp() async throws {
        suiteName = "zoho.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychain = KeychainService(service: "com.pezy.gmail.tests.\(UUID().uuidString)")
        authorizer = MockAuthorizer()
        api = MockZohoAPI()
        notifier = URLRecordingNotifier()
        let auth = AuthService(keychain: keychain, authorizer: authorizer, userDefaults: defaults)
        let session = AuthSession(
            accessToken: "a", refreshToken: "r", idToken: nil,
            expiresAt: Date().addingTimeInterval(3600), email: "hello@designbookmark.com", dataCenter: "com"
        )
        try keychain.save(JSONEncoder().encode(session), account: "hello@designbookmark.com")
        try auth.restore(email: "hello@designbookmark.com")
        account = AccountState(email: "hello@designbookmark.com", colorIndex: 4, provider: .zoho, dataCenter: .com)
        coordinator = ZohoPollingCoordinator(
            account: account, auth: auth, api: api, scheduler: MockScheduler(),
            notifier: notifier, userDefaults: defaults
        )
    }

    override func tearDown() async throws {
        try? keychain.delete(account: "hello@designbookmark.com")
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFirstTickLoadsMessagesAndCountWithoutNotifying() async {
        api.listResult = .success([zohoMessage("m1", minutesAgo: 5), zohoMessage("m2", minutesAgo: 1)])
        await coordinator.performTick()
        XCTAssertEqual(account.unreadCount, 2)
        XCTAssertEqual(account.emails.count, 2)
        XCTAssertEqual(account.loadState, .loaded)
        XCTAssertTrue(notifier.notified.isEmpty, "mail already there at first launch must not spam banners")
    }

    func testLaterTickNotifiesOnlyNewMessagesWithZohoURL() async {
        api.listResult = .success([zohoMessage("m1")])
        await coordinator.performTick()
        api.listResult = .success([zohoMessage("m2"), zohoMessage("m1", minutesAgo: 2)])
        await coordinator.performTick()

        XCTAssertEqual(notifier.notified.map(\.id), ["m2"])
        XCTAssertEqual(notifier.urls.map(\.absoluteString), ["https://mail.zoho.com/zm/#mail/folder/inbox/p/m2"])
        XCTAssertTrue(notifier.gmailNotified.isEmpty)
        XCTAssertEqual(account.unreadCount, 2)
    }

    func testSeenIdsSurviveARestartSoOfflineMailStillNotifies() async throws {
        api.listResult = .success([zohoMessage("m1")])
        await coordinator.performTick()
        // Relaunch: a fresh coordinator over the same defaults.
        let auth = AuthService(keychain: keychain, authorizer: authorizer, userDefaults: defaults)
        try auth.restore(email: "hello@designbookmark.com")
        let relaunched = ZohoPollingCoordinator(
            account: AccountState(email: account.email, colorIndex: 4, provider: .zoho, dataCenter: .com),
            auth: auth, api: api, scheduler: MockScheduler(), notifier: notifier, userDefaults: defaults
        )
        api.listResult = .success([zohoMessage("m1"), zohoMessage("m9")])
        await relaunched.performTick()
        XCTAssertEqual(notifier.notified.map(\.id), ["m9"])
    }

    func testCountComesFromWholeUnreadListWhileUIShowsTheNewest() async {
        api.listResult = .success((0..<57).map { zohoMessage("m\($0)", minutesAgo: Double($0)) })
        await coordinator.performTick()
        XCTAssertEqual(account.unreadCount, 57)
        XCTAssertEqual(account.emails.count, ZohoPollingCoordinator.visibleMessages)
        XCTAssertEqual(account.emails.first?.id, "m0")
    }

    func testMarkAsReadDropsMessageAndRecounts() async {
        api.listResult = .success([zohoMessage("m1"), zohoMessage("m2", minutesAgo: 3)])
        await coordinator.performTick()

        await coordinator.markAsRead(zohoMessage("m1"))

        XCTAssertEqual(api.markedIds, ["m1"])
        XCTAssertEqual(account.emails.map(\.id), ["m2"])
        XCTAssertEqual(account.unreadCount, 1)
        XCTAssertTrue(notifier.notified.isEmpty)
    }

    func testUnauthorizedMarksAccountForSignIn() async {
        api.listResult = .failure(AppError.api(.unauthorized))
        await coordinator.performTick()
        XCTAssertEqual(account.authState, .needsReauthorization)
    }

    func testMissingTokensNeedSignInWithoutCallingZoho() async throws {
        let auth = AuthService(keychain: keychain, authorizer: authorizer, userDefaults: defaults)  // no restore
        let lonely = AccountState(email: "x@y.com", colorIndex: 0, provider: .zoho)
        let poller = ZohoPollingCoordinator(account: lonely, auth: auth, api: api, scheduler: MockScheduler(), userDefaults: defaults)
        await poller.performTick()
        XCTAssertEqual(lonely.authState, .needsReauthorization)
        XCTAssertEqual(api.listCallCount, 0)
    }
}

@MainActor
final class ZohoAccountManagerTests: XCTestCase {
    private var appState: AppState!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: KeychainService!
    private var gmailAuthorizer: MockAuthorizer!
    private var zohoAuthorizer: MockAuthorizer!
    private var gmailAPI: MockAPI!
    private var zohoAPI: MockZohoAPI!
    private var manager: AccountManager!

    override func setUp() async throws {
        appState = AppState()
        suiteName = "zohomgr.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychain = KeychainService(service: "com.pezy.gmail.tests.\(UUID().uuidString)")
        gmailAuthorizer = MockAuthorizer()
        zohoAuthorizer = MockAuthorizer()
        gmailAPI = MockAPI()
        zohoAPI = MockZohoAPI()
        manager = makeManager()
    }

    override func tearDown() async throws {
        for email in ["a@example.com", "hello@designbookmark.com", "noah@designbookmark.com", KeychainService.pendingAccount] {
            try? keychain.delete(account: email)
        }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func signInZoho(dataCenter: String = "com") {
        zohoAuthorizer.initialResult = .success(AuthSession(
            accessToken: "zat", refreshToken: "zrt", idToken: nil,
            expiresAt: Date().addingTimeInterval(3600), email: nil, dataCenter: dataCenter
        ))
        zohoAPI.listResult = .success([zohoMessage("z1"), zohoMessage("z2", minutesAgo: 4), zohoMessage("z3", minutesAgo: 9)])
    }

    private func signInGmail(_ email: String) {
        gmailAuthorizer.initialResult = .success(AuthSession(
            accessToken: "gat", refreshToken: "grt", idToken: nil,
            expiresAt: Date().addingTimeInterval(3600), email: nil
        ))
        gmailAPI.profileResult = .success(GmailProfile(emailAddress: email, historyId: "10", messagesTotal: 0))
        gmailAPI.listResult = .success(MessageListResponse(messageIds: [], resultSizeEstimate: 0))
        gmailAPI.inboxUnreadCountResult = .success(4)
        gmailAPI.historyResult = .success(HistoryResponse(historyId: "11", changes: []))
    }

    func testAddZohoAccountUsesTheAliasAndStoresProviderAndDataCenter() async throws {
        signInZoho(dataCenter: "eu")
        let email = try await manager.addZohoAccount(mode: .externalBrowser(loginHint: "hello@designbookmark.com"),
                                                     loginHint: "hello@designbookmark.com")

        XCTAssertEqual(email, "hello@designbookmark.com")
        XCTAssertEqual(zohoAuthorizer.lastSignInMode, .externalBrowser(loginHint: "hello@designbookmark.com"))
        XCTAssertNil(defaults.string(forKey: AuthService.lastEmailDefaultsKey), "Zoho must not touch the Gmail-era pointer")
        let stored = try XCTUnwrap(AccountStore(defaults: defaults).load().first)
        XCTAssertEqual(stored.provider, .zoho)
        XCTAssertEqual(stored.dataCenter, .eu)
        let state = try XCTUnwrap(appState.account(for: email))
        XCTAssertEqual(state.provider, .zoho)
        XCTAssertEqual(state.unreadCount, 3)
        XCTAssertNil(try keychain.load(account: KeychainService.pendingAccount))
        let saved = try JSONDecoder().decode(AuthSession.self, from: XCTUnwrap(try keychain.load(account: email)))
        XCTAssertEqual(saved.dataCenter, "eu")
        XCTAssertEqual(saved.email, email)
    }

    func testWithoutHintTheMailboxPrimaryAddressIsUsed() async throws {
        signInZoho()
        let email = try await manager.addZohoAccount()
        XCTAssertEqual(email, "noah@designbookmark.com")
    }

    func testSigningInAgainViaAnotherAliasReplacesInsteadOfDuplicating() async throws {
        signInZoho()
        try await manager.addZohoAccount(loginHint: "hello@designbookmark.com")
        appState.accounts[0].authState = .needsReauthorization
        signInZoho()
        let email = try await manager.addZohoAccount(loginHint: "noah@designbookmark.com")

        XCTAssertEqual(email, "hello@designbookmark.com")
        XCTAssertEqual(appState.accounts.count, 1)
        XCTAssertEqual(appState.accounts[0].authState, .signedIn(email: "hello@designbookmark.com"))
    }

    func testUnreadTotalAddsAcrossProviders() async throws {
        signInGmail("a@example.com")
        try await manager.addAccount()
        signInZoho()
        try await manager.addZohoAccount(loginHint: "hello@designbookmark.com")

        XCTAssertEqual(appState.accounts.map(\.provider), [.gmail, .zoho])
        XCTAssertEqual(appState.totalUnreadCount, 7)
        XCTAssertEqual(appState.accounts.map(\.colorIndex), [0, 1])
    }

    func testZohoFailureNeverTouchesGmailAndViceVersa() async throws {
        signInGmail("a@example.com")
        try await manager.addAccount()
        signInZoho()
        try await manager.addZohoAccount(loginHint: "hello@designbookmark.com")

        zohoAPI.listResult = .failure(AppError.api(.serverError(status: 503)))
        await manager.refreshAll()
        let gmail = try XCTUnwrap(appState.account(for: "a@example.com"))
        let zoho = try XCTUnwrap(appState.account(for: "hello@designbookmark.com"))
        XCTAssertNil(gmail.lastError)
        XCTAssertEqual(gmail.unreadCount, 4)
        XCTAssertEqual(zoho.lastError, .api(.serverError(status: 503)))

        zohoAPI.listResult = .success([zohoMessage("z1")])
        gmailAPI.historyResult = .failure(AppError.api(.serverError(status: 500)))
        await manager.refreshAll()
        XCTAssertNil(zoho.lastError)
        XCTAssertEqual(zoho.unreadCount, 1)
        XCTAssertEqual(gmail.lastError, .api(.serverError(status: 500)))
    }

    func testRestoreRebuildsBothProvidersAndFlagsMissingTokens() async throws {
        signInGmail("a@example.com")
        try await manager.addAccount()
        signInZoho()
        try await manager.addZohoAccount(loginHint: "hello@designbookmark.com")
        AccountStore(defaults: defaults).add(email: "noah@designbookmark.com", provider: .zoho, dataCenter: .com)  // no tokens

        let relaunched = AppState()
        let fresh = makeManager(appState: relaunched)
        gmailAPI.historyResult = .success(HistoryResponse(historyId: "11", changes: []))
        await fresh.restoreAll()

        XCTAssertEqual(relaunched.account(for: "hello@designbookmark.com")?.provider, .zoho)
        XCTAssertEqual(relaunched.account(for: "hello@designbookmark.com")?.unreadCount, 3)
        XCTAssertEqual(relaunched.account(for: "noah@designbookmark.com")?.authState, .needsReauthorization)
        XCTAssertEqual(relaunched.account(for: "a@example.com")?.authState, .signedIn(email: "a@example.com"))
    }

    func testBuildWithoutZohoClientHidesItAndKeepsStoredAccountListed() async throws {
        AccountStore(defaults: defaults).add(email: "hello@designbookmark.com", provider: .zoho, dataCenter: .com)
        let plain = AppState()
        let noZoho = makeManager(appState: plain, zoho: false)
        XCTAssertFalse(plain.isZohoConfigured)
        await noZoho.restoreAll()
        XCTAssertEqual(plain.accounts.map(\.email), ["hello@designbookmark.com"])
        XCTAssertEqual(plain.accounts.first?.authState, .needsReauthorization)
        do {
            try await noZoho.addZohoAccount()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(plain.accounts.count, 1)
        }
        XCTAssertTrue(appState.isZohoConfigured)
    }

    func testRemoveZohoAccountRevokesAndClearsOnlyThatAccount() async throws {
        signInGmail("a@example.com")
        try await manager.addAccount()
        signInZoho()
        try await manager.addZohoAccount(loginHint: "hello@designbookmark.com")

        await manager.removeAccount(email: "hello@designbookmark.com")

        XCTAssertEqual(appState.accounts.map(\.email), ["a@example.com"])
        XCTAssertNil(try keychain.load(account: "hello@designbookmark.com"))
        XCTAssertNotNil(try keychain.load(account: "a@example.com"))
        XCTAssertNil(defaults.stringArray(forKey: ZohoPollingCoordinator.seenIdsKey(for: "hello@designbookmark.com")))
        XCTAssertEqual(zohoAuthorizer.revokeCallCount, 1)
        XCTAssertEqual(gmailAuthorizer.revokeCallCount, 0)
    }

    func testMarkAsReadRoutesToTheRightProvider() async throws {
        signInGmail("a@example.com")
        try await manager.addAccount()
        signInZoho()
        try await manager.addZohoAccount(loginHint: "hello@designbookmark.com")

        await manager.markAsRead(zohoMessage("z1"), in: "hello@designbookmark.com")

        XCTAssertEqual(zohoAPI.markedIds, ["z1"])
        XCTAssertEqual(appState.account(for: "hello@designbookmark.com")?.unreadCount, 2)
        XCTAssertEqual(appState.account(for: "a@example.com")?.unreadCount, 4)
    }

    func testIntervalPropagatesToZohoPollersToo() async throws {
        signInZoho()
        try await manager.addZohoAccount()
        manager.interval = 300
        XCTAssertEqual(manager.coordinators.values.map(\.interval), [300])
    }

    private func makeManager(appState: AppState? = nil, zoho: Bool = true) -> AccountManager {
        let config: ZohoProviderConfig? = zoho ? ZohoProviderConfig(
            signIn: zohoAuthorizer,
            cancelSignIn: {},
            makeAuthorizer: { [zohoAuthorizer] _ in zohoAuthorizer! },
            makeAPI: { [zohoAPI] _ in zohoAPI! }
        ) : nil
        return AccountManager(
            appState: appState ?? self.appState,
            store: AccountStore(defaults: defaults),
            keychain: keychain,
            authorizer: gmailAuthorizer,
            api: gmailAPI,
            zoho: config,
            notifier: nil,
            userDefaults: defaults,
            makeScheduler: { MockScheduler() }
        )
    }
}

@MainActor
final class ProviderModelTests: XCTestCase {
    func testStoredAccountFromBeforeZohoDecodesAsGmail() throws {
        let legacy = Data(#"[{"email":"a@example.com","colorIndex":2}]"#.utf8)
        let decoded = try JSONDecoder().decode([StoredAccount].self, from: legacy)
        XCTAssertEqual(decoded, [StoredAccount(email: "a@example.com", colorIndex: 2, provider: .gmail)])
    }

    func testStoredZohoAccountRoundTrips() throws {
        let account = StoredAccount(email: "h@d.com", colorIndex: 1, provider: .zoho, dataCenter: .comAu)
        let data = try JSONEncoder().encode([account])
        XCTAssertEqual(try JSONDecoder().decode([StoredAccount].self, from: data), [account])
    }

    func testStatusShowsProviderPerAccountAndAddResult() throws {
        let state = AppState()
        let gmail = AccountState(email: "a@example.com", colorIndex: 0)
        let zoho = AccountState(email: "hello@designbookmark.com", colorIndex: 1, provider: .zoho, dataCenter: .com)
        zoho.unreadCount = 3
        state.accounts = [gmail, zoho]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = AutomationStatusWriter(appState: state, fileURL: dir.appendingPathComponent("s.json"))
        writer.recordAddAccount(email: "hello@designbookmark.com", loginHint: nil, error: nil, provider: .zoho)

        let data = try AutomationStatus.encoder().encode(writer.snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.map { $0["provider"] as? String }, ["gmail", "zoho"])
        XCTAssertEqual(accounts[1]["unreadCount"] as? Int, 3)
        XCTAssertEqual((object["lastAddAccount"] as? [String: Any])?["provider"] as? String, "zoho")
        let lowered = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["token", "secret", "refresh", "access"] {
            XCTAssertFalse(lowered.contains(forbidden))
        }
    }

    func testOldStatusFileWithoutProviderStillDecodes() throws {
        let old = Data("""
        {"updatedAt":"2026-10-31T10:00:00Z","addAccountInProgress":false,
         "accounts":[{"email":"a@example.com","state":"ok","unreadCount":1}],
         "lastAddAccount":{"email":"a@example.com","ok":true,"finishedAt":"2026-10-31T09:00:00Z"}}
        """.utf8)
        let status = try AutomationStatus.decoder().decode(AutomationStatus.self, from: old)
        XCTAssertNil(status.accounts[0].provider)
        XCTAssertNil(status.lastAddAccount?.provider)
    }

    func testWebURLsFollowTheProvider() {
        let message = zohoMessage("77")
        let zoho = AccountState(email: "h@d.com", colorIndex: 0, provider: .zoho, dataCenter: .eu)
        XCTAssertEqual(zoho.webURL(for: message).absoluteString, "https://mail.zoho.eu/zm/#mail/folder/inbox/p/77")
        XCTAssertEqual(zoho.inboxURL.absoluteString, "https://mail.zoho.eu/zm/#mail/folder/inbox")
        let gmail = AccountState(email: "a@example.com", colorIndex: 0)
        XCTAssertEqual(gmail.webURL(for: message), GmailWebURL.thread(email: "a@example.com", threadId: "77"))
        XCTAssertEqual(gmail.inboxURL, GmailWebURL.inbox(email: "a@example.com"))
    }
}
