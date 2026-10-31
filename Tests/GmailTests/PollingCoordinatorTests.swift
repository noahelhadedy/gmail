import XCTest
@testable import Gmail

@MainActor
final class PollingCoordinatorTests: XCTestCase {
    private var account: AccountState!
    private var keychain: KeychainService!
    private var authorizer: MockAuthorizer!
    private var auth: AuthService!
    private var api: MockAPI!
    private var scheduler: MockScheduler!
    private var notifier: RecordingNotifier!
    private var defaults: UserDefaults!
    private var coordinator: PollingCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        account = AccountState(email: "alice@example.com", colorIndex: 0)
        keychain = KeychainService(service: "com.pezy.gmail.tests.\(UUID().uuidString)")
        authorizer = MockAuthorizer()
        auth = AuthService(keychain: keychain, authorizer: authorizer)
        api = MockAPI()
        scheduler = MockScheduler()
        notifier = RecordingNotifier()
        let suiteName = "polling.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        coordinator = PollingCoordinator(
            account: account,
            auth: auth,
            api: api,
            scheduler: scheduler,
            notifier: notifier,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().description)
        try? keychain.delete(account: KeychainService.pendingAccount)
        try? keychain.delete(account: "alice@example.com")
        try await super.tearDown()
    }

    func testStartWithoutSessionStaysIdle() async {
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(scheduler.scheduleCount, 0)
    }

    func testStartWithSessionTransitionsToPolling() async throws {
        try await signInTestSession()
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .polling)
        XCTAssertEqual(scheduler.scheduleCount, 1)
    }

    func testPopoverOpenedPausesPolling() async throws {
        try await signInTestSession()
        await coordinator.start()
        await coordinator.popoverOpened()
        XCTAssertEqual(coordinator.state, .paused(.popoverOpen))
        XCTAssertEqual(scheduler.invalidateCount, 1)
    }

    func testPopoverClosedFetchesAndResumes() async throws {
        try await signInTestSession()
        api.profileResult = .success(makeProfile(historyId: "100"))
        api.listResult = .success(MessageListResponse(messageIds: [], resultSizeEstimate: 0))
        await coordinator.start()
        await coordinator.popoverOpened()

        await coordinator.popoverClosed()

        XCTAssertEqual(coordinator.state, .polling)
        XCTAssertEqual(api.profileCallCount, 1, "popoverClosed should immediately fetch once")
    }

    func testNetworkOfflineDuringPollingPauses() async throws {
        try await signInTestSession()
        await coordinator.start()
        await coordinator.networkChanged(to: .offline)
        XCTAssertEqual(coordinator.state, .paused(.network))
    }

    func testNetworkRestoreFromPausedFetches() async throws {
        try await signInTestSession()
        api.profileResult = .success(makeProfile(historyId: "100"))
        api.listResult = .success(MessageListResponse(messageIds: [], resultSizeEstimate: 0))
        await coordinator.start()
        await coordinator.networkChanged(to: .offline)

        await coordinator.networkChanged(to: .online)

        XCTAssertEqual(coordinator.state, .polling)
        XCTAssertEqual(api.profileCallCount, 1)
    }

    func testFetchInitialAttachesEmailAndPopulatesEmails() async throws {
        try await signInTestSession()
        api.profileResult = .success(makeProfile(emailAddress: "alice@example.com", historyId: "100"))
        api.listResult = .success(MessageListResponse(messageIds: ["m1"], resultSizeEstimate: 1))
        api.getResults["m1"] = .success(makeEmail(id: "m1", subject: "Hi"))
        api.inboxUnreadCountResult = .success(200)  // authoritative INBOX count

        await coordinator.performTick()

        XCTAssertEqual(account.authState, .signedIn(email: "alice@example.com"))
        XCTAssertEqual(account.emails.count, 1)
        XCTAssertEqual(account.emails.first?.subject, "Hi")
        XCTAssertEqual(account.unreadCount, 200,
                       "unreadCount must come from labels.get(INBOX), not from the visible list count")
        XCTAssertEqual(coordinator.lastHistoryId, "100")
    }

    /// Regression: a stale lastHistoryId from a previous binary or account would
    /// route a fresh sign-in down fetchIncremental, bypassing attachEmail and
    /// leaving authState stuck at .signedOut. Coordinator must recover.
    func testStaleHistoryIdWithoutEmailFallsBackToFetchInitial() async throws {
        try await signInTestSession()  // session has email == nil (just-signed-in)
        coordinator.lastHistoryId = "100"  // stale from previous run

        api.profileResult = .success(makeProfile(emailAddress: "alice@example.com", historyId: "200"))
        api.listResult = .success(MessageListResponse(messageIds: [], resultSizeEstimate: 0))

        await coordinator.performTick()

        XCTAssertEqual(api.profileCallCount, 1, "Must call getProfile to learn email")
        XCTAssertEqual(account.authState, .signedIn(email: "alice@example.com"))
        XCTAssertEqual(coordinator.lastHistoryId, "200", "Should adopt fresh historyId from profile")
    }

    func testFetchIncrementalRemovesMessagesOnLabelsRemoved() async throws {
        try await signInTestSession()
        coordinator.lastHistoryId = "100"
        try auth.attachEmail("alice@example.com")
        account.emails = [
            makeEmail(id: "m1", subject: "old1"),
            makeEmail(id: "m2", subject: "old2")
        ]
        account.unreadCount = 199

        api.historyResult = .success(HistoryResponse(
            historyId: "200",
            changes: [.labelRemoved(messageId: "m1", label: "UNREAD")]
        ))
        api.inboxUnreadCountResult = .success(198)  // one fewer after the label removal

        await coordinator.performTick()

        XCTAssertEqual(account.emails.map(\.id), ["m2"])
        XCTAssertEqual(account.unreadCount, 198,
                       "unreadCount must reflect labels.get(INBOX), not the visible list size")
        XCTAssertEqual(coordinator.lastHistoryId, "200")
    }

    /// Regression: history.list?labelId=INBOX excluded deleted messages (they no longer carry
    /// INBOX when the query runs). Coordinator never saw the deletion, count stayed stale.
    /// Fix: drop the server-side labelId filter and use the labelIds embedded in each record.
    func testFetchIncrementalHandlesMessageDeleted() async throws {
        try await signInTestSession()
        coordinator.lastHistoryId = "100"
        try auth.attachEmail("alice@example.com")
        account.emails = [
            makeEmail(id: "m1", subject: "to delete"),
            makeEmail(id: "m2", subject: "keep")
        ]
        account.unreadCount = 5

        api.historyResult = .success(HistoryResponse(
            historyId: "200",
            changes: [.messageDeleted(id: "m1", labelIds: ["INBOX", "UNREAD"])]
        ))
        api.inboxUnreadCountResult = .success(4)

        await coordinator.performTick()

        XCTAssertEqual(account.emails.map(\.id), ["m2"], "deleted message must leave the list")
        XCTAssertEqual(account.unreadCount, 4, "count must refresh after deletion")
        XCTAssertEqual(coordinator.lastHistoryId, "200")
    }

    /// Regression: incremental polling used to set unreadCount = emails.count, which
    /// caps at maxResults (20). User saw "200 unread" jump to "20" after the first
    /// 60s tick. The fix routes unreadCount through labels.get(INBOX).messagesUnread.
    func testIncrementalPollingDoesNotCollapseUnreadCountToVisibleListCap() async throws {
        try await signInTestSession()
        coordinator.lastHistoryId = "100"
        try auth.attachEmail("alice@example.com")
        // Visible list capped at 20, but real INBOX has 200 unread.
        account.emails = (0..<20).map { makeEmail(id: "m\($0)", subject: "old\($0)") }
        account.unreadCount = 200

        api.historyResult = .success(HistoryResponse(
            historyId: "200",
            changes: [.messageAdded(id: "new1", labelIds: ["INBOX", "UNREAD"])]
        ))
        api.getResults["new1"] = .success(makeEmail(id: "new1", subject: "fresh"))
        api.inboxUnreadCountResult = .success(201)  // 200 + 1 newly added

        await coordinator.performTick()

        XCTAssertEqual(account.unreadCount, 201,
                       "Must NOT collapse to emails.count (~20) — that was the bug")
        XCTAssertGreaterThanOrEqual(account.emails.count, 20)
    }

    func testFetchIncrementalAddsNewMessageAndNotifies() async throws {
        try await signInTestSession()
        coordinator.lastHistoryId = "100"
        try auth.attachEmail("alice@example.com")

        api.historyResult = .success(HistoryResponse(
            historyId: "200",
            changes: [.messageAdded(id: "m1", labelIds: ["INBOX", "UNREAD"])]
        ))
        api.getResults["m1"] = .success(makeEmail(id: "m1", subject: "Fresh"))

        await coordinator.performTick()

        XCTAssertEqual(notifier.notified.map(\.id), ["m1"])
        XCTAssertEqual(notifier.accounts, ["alice@example.com"], "notification must name the account")
        XCTAssertEqual(account.emails.first?.subject, "Fresh")
    }

    func testHistoryExpiredFallsBackToFetchInitial() async throws {
        try await signInTestSession()
        coordinator.lastHistoryId = "100"
        try auth.attachEmail("alice@example.com")

        api.historyResult = .failure(AppError.api(.historyExpired))
        api.profileResult = .success(makeProfile(emailAddress: "alice@example.com", historyId: "300"))
        api.listResult = .success(MessageListResponse(messageIds: [], resultSizeEstimate: 0))

        await coordinator.performTick()

        XCTAssertEqual(coordinator.lastHistoryId, "300")
        XCTAssertEqual(api.profileCallCount, 1)
    }

    func testRefreshTokenInvalidMarksReauthorization() async throws {
        try await signInTestSession()
        api.profileResult = .failure(AppError.auth(.refreshTokenInvalid))

        await coordinator.performTick()

        XCTAssertEqual(account.authState, .needsReauthorization)
        XCTAssertEqual(account.lastError, .auth(.refreshTokenInvalid))
    }

    func testHistoryIdIsStoredPerAccount() async throws {
        coordinator.lastHistoryId = "123"
        XCTAssertEqual(defaults.string(forKey: "lastHistoryId.alice@example.com"), "123")
        XCTAssertNil(defaults.string(forKey: "lastHistoryId"), "must not use the old shared key")

        coordinator.clearPersistedState()
        XCTAssertNil(coordinator.lastHistoryId)
    }

    func testIncrementalPollAlwaysRefreshesUnreadCount() async throws {
        try await signInTestSession()
        coordinator.lastHistoryId = "100"
        try auth.attachEmail("alice@example.com")
        account.unreadCount = 3
        api.historyResult = .success(HistoryResponse(historyId: "101", changes: []))
        api.inboxUnreadCountResult = .success(7)

        await coordinator.performTick()

        XCTAssertEqual(account.unreadCount, 7, "count refreshes on every poll, even with no history changes")
    }

    func testTickWithoutTokensMarksNeedsReauthorization() async {
        await coordinator.performTick()
        XCTAssertEqual(account.authState, .needsReauthorization)
        XCTAssertEqual(api.profileCallCount, 0)
    }

    func testMarkAsReadRemovesMessageAndRefreshesCount() async throws {
        try await signInTestSession()
        try auth.attachEmail("alice@example.com")
        let message = makeEmail(id: "m1", subject: "read me")
        account.emails = [message, makeEmail(id: "m2", subject: "keep")]
        account.unreadCount = 10
        api.inboxUnreadCountResult = .success(9)

        await coordinator.markAsRead(message)

        XCTAssertEqual(api.markedAsRead, ["m1"])
        XCTAssertEqual(account.emails.map(\.id), ["m2"])
        XCTAssertEqual(account.unreadCount, 9)
    }

    func testMarkAsReadFailureKeepsMessage() async throws {
        try await signInTestSession()
        try auth.attachEmail("alice@example.com")
        let message = makeEmail(id: "m1", subject: "read me")
        account.emails = [message]
        account.unreadCount = 1
        api.markAsReadError = AppError.api(.serverError(status: 500))

        await coordinator.markAsRead(message)

        XCTAssertEqual(account.emails.map(\.id), ["m1"])
        XCTAssertEqual(account.unreadCount, 1)
        XCTAssertEqual(account.lastError, .api(.serverError(status: 500)))
    }

    func testStopInvalidatesScheduler() async throws {
        try await signInTestSession()
        await coordinator.start()
        await coordinator.stop()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertGreaterThanOrEqual(scheduler.invalidateCount, 1)
    }

    private func signInTestSession() async throws {
        authorizer.initialResult = .success(AuthSession(
            accessToken: "atoken",
            refreshToken: "rtoken",
            idToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            email: nil
        ))
        _ = try await auth.signIn()
    }

    private func makeProfile(emailAddress: String = "alice@example.com", historyId: String) -> GmailProfile {
        GmailProfile(emailAddress: emailAddress, historyId: historyId, messagesTotal: 0)
    }

    private func makeEmail(id: String, subject: String) -> EmailMessage {
        EmailMessage(
            id: id,
            threadId: "t-\(id)",
            from: "x@example.com",
            subject: subject,
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: nil
        )
    }
}

final class MockAPI: GmailAPIClienting, @unchecked Sendable {
    var profileResult: Result<GmailProfile, Error> = .failure(NSError(domain: "mock", code: 0))
    var listResult: Result<MessageListResponse, Error> = .failure(NSError(domain: "mock", code: 0))
    var historyResult: Result<HistoryResponse, Error> = .failure(NSError(domain: "mock", code: 0))
    var getResults: [String: Result<EmailMessage, Error>] = [:]
    var inboxUnreadCountResult: Result<Int, Error> = .success(0)
    var profileCallCount = 0
    var historyCallCount = 0
    var inboxUnreadCallCount = 0

    func getProfile(accessToken: String) async throws -> GmailProfile {
        profileCallCount += 1
        return try profileResult.get()
    }

    func listUnreadMessages(accessToken: String, maxResults: Int) async throws -> MessageListResponse {
        try listResult.get()
    }

    func getMessageMetadata(accessToken: String, id: String) async throws -> EmailMessage {
        guard let result = getResults[id] else {
            throw AppError.api(.malformedResponse)
        }
        return try result.get()
    }

    func listHistory(accessToken: String, startHistoryId: String) async throws -> HistoryResponse {
        historyCallCount += 1
        return try historyResult.get()
    }

    func getInboxUnreadCount(accessToken: String) async throws -> Int {
        inboxUnreadCallCount += 1
        return try inboxUnreadCountResult.get()
    }

    var markAsReadError: Error?
    var markedAsRead: [String] = []

    func markAsRead(accessToken: String, id: String) async throws {
        if let markAsReadError { throw markAsReadError }
        markedAsRead.append(id)
    }
}

final class MockScheduler: PollScheduling, @unchecked Sendable {
    var scheduleCount = 0
    var invalidateCount = 0
    var lastAction: (@Sendable () async -> Void)?

    func schedule(interval: TimeInterval, action: @escaping @Sendable () async -> Void) async {
        scheduleCount += 1
        lastAction = action
    }

    func invalidate() async {
        invalidateCount += 1
    }
}

private final class RecordingNotifier: PollingNotifying, @unchecked Sendable {
    var notified: [EmailMessage] = []
    var accounts: [String] = []

    func notifyNewMessages(_ messages: [EmailMessage], account: String) async {
        notified.append(contentsOf: messages)
        accounts.append(account)
    }
}
