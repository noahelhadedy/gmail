import XCTest
@testable import Gmail

@MainActor
final class AppStateTests: XCTestCase {
    func testInitialState() {
        let state = AppState()
        XCTAssertEqual(state.accounts.count, 0)
        XCTAssertEqual(state.totalUnreadCount, 0)
        XCTAssertEqual(state.connectionState, .unknown)
        XCTAssertEqual(state.aggregateAuthState, .signedOut)
        XCTAssertNil(state.topPriorityError)
    }

    func testNewAccountStartsSignedIn() {
        let account = AccountState(email: "alice@example.com", colorIndex: 0)
        XCTAssertEqual(account.authState, .signedIn(email: "alice@example.com"))
        XCTAssertEqual(account.id, "alice@example.com")
        XCTAssertFalse(account.needsReauthorization)
    }

    func testTotalUnreadSumsAllAccounts() {
        let state = AppState()
        state.accounts = [
            makeAccount("a@example.com", unread: 3),
            makeAccount("b@example.com", unread: 0),
            makeAccount("c@example.com", unread: 12)
        ]
        XCTAssertEqual(state.totalUnreadCount, 15)
    }

    func testTotalUnreadIsZeroWhenAllAccountsEmpty() {
        let state = AppState()
        state.accounts = [makeAccount("a@example.com", unread: 0), makeAccount("b@example.com", unread: 0)]
        XCTAssertEqual(state.totalUnreadCount, 0)
    }

    func testAggregateAuthStateFlagsAnyAccountNeedingReauthorization() {
        let state = AppState()
        let broken = makeAccount("b@example.com", unread: 0)
        broken.authState = .needsReauthorization
        state.accounts = [makeAccount("a@example.com", unread: 1), broken]
        XCTAssertEqual(state.aggregateAuthState, .needsReauthorization)
    }

    func testAggregateAuthStateSignedInWhenAllHealthy() {
        let state = AppState()
        state.accounts = [makeAccount("a@example.com", unread: 1)]
        XCTAssertEqual(state.aggregateAuthState, .signedIn(email: "a@example.com"))
    }

    func testTopPriorityErrorPicksHighestAcrossAccounts() {
        let state = AppState()
        let a = makeAccount("a@example.com", unread: 0)
        let b = makeAccount("b@example.com", unread: 0)
        a.lastError = .api(.serverError(status: 500))
        b.lastError = .network(.offline)
        state.accounts = [a, b]
        XCTAssertEqual(state.topPriorityError, .network(.offline))
    }

    func testAccountLookupIsCaseInsensitive() {
        let state = AppState()
        state.accounts = [makeAccount("Hello@DjectStudio.com", unread: 0)]
        XCTAssertEqual(state.account(for: "hello@djectstudio.com")?.email, "Hello@DjectStudio.com")
        XCTAssertNil(state.account(for: "other@example.com"))
    }

    func testAccountResetClearsMailButKeepsIdentity() {
        let account = makeAccount("a@example.com", unread: 4)
        account.emails = [makeEmail("m1")]
        account.loadState = .loaded
        account.lastError = .auth(.refreshTokenInvalid)

        account.reset()

        XCTAssertEqual(account.emails, [])
        XCTAssertEqual(account.unreadCount, 0)
        XCTAssertEqual(account.loadState, .idle)
        XCTAssertNil(account.lastError)
        XCTAssertEqual(account.email, "a@example.com")
    }

    func testResetClearsAccounts() {
        let state = AppState()
        state.accounts = [makeAccount("a@example.com", unread: 2)]
        state.connectionState = .online
        state.reset()
        XCTAssertEqual(state.accounts.count, 0)
        XCTAssertEqual(state.connectionState, .unknown)
    }

    private func makeAccount(_ email: String, unread: Int) -> AccountState {
        let account = AccountState(email: email, colorIndex: 0)
        account.unreadCount = unread
        return account
    }

    private func makeEmail(_ id: String) -> EmailMessage {
        EmailMessage(
            id: id,
            threadId: "t-\(id)",
            from: "alice@example.com",
            subject: "Hello",
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: nil
        )
    }
}
