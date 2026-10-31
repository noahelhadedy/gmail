import XCTest
@testable import Gmail

@MainActor
final class AuthServiceTests: XCTestCase {
    private var keychain: KeychainService!
    private var authorizer: MockAuthorizer!
    private var clock: TestClock!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var service: AuthService!

    override func setUp() async throws {
        try await super.setUp()
        keychain = KeychainService(service: "com.pezy.gmail.tests.\(UUID().uuidString)")
        authorizer = MockAuthorizer()
        clock = TestClock(initial: Date(timeIntervalSince1970: 1_700_000_000))
        defaultsSuiteName = "auth.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let clockRef = clock!
        service = AuthService(
            keychain: keychain,
            authorizer: authorizer,
            userDefaults: defaults,
            now: { clockRef.now() }
        )
    }

    override func tearDown() async throws {
        try? keychain.delete(account: KeychainService.pendingAccount)
        try? keychain.delete(account: "alice@example.com")
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try await super.tearDown()
    }

    func testSignInPersistsSessionUnderPendingAccount() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))

        let session = try await service.signIn()

        XCTAssertEqual(session.accessToken, "a1")
        XCTAssertNotNil(try keychain.load(account: KeychainService.pendingAccount))
        XCTAssertNil(try keychain.load(account: "alice@example.com"))
    }

    func testAttachEmailMigratesPendingToEmailAccount() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()

        try service.attachEmail("alice@example.com")

        XCTAssertNil(try keychain.load(account: KeychainService.pendingAccount))
        XCTAssertNotNil(try keychain.load(account: "alice@example.com"))
        XCTAssertEqual(service.session?.email, "alice@example.com")
    }

    func testFreshAccessTokenReturnsCachedWhenNotExpired() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()

        let token = try await service.freshAccessToken()

        XCTAssertEqual(token, "a1")
        XCTAssertEqual(authorizer.refreshCallCount, 0)
    }

    func testFreshAccessTokenRefreshesWhenExpired() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 30))
        _ = try await service.signIn()
        clock.advance(120)
        authorizer.refreshResult = .success(makeSession(access: "a2", expiresIn: 3600, refresh: ""))

        let token = try await service.freshAccessToken()

        XCTAssertEqual(token, "a2")
        XCTAssertEqual(authorizer.refreshCallCount, 1)
        XCTAssertEqual(service.session?.refreshToken, "r1",
                       "Empty refresh response should keep prior refresh_token")
    }

    func testFreshAccessTokenSurfacesRefreshTokenInvalid() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 30))
        _ = try await service.signIn()
        clock.advance(120)
        authorizer.refreshResult = .failure(NSError(domain: "test", code: 401))

        do {
            _ = try await service.freshAccessToken()
            XCTFail("expected refresh to fail")
        } catch AppError.auth(.refreshTokenInvalid) {
            XCTAssertNil(service.session)
            XCTAssertNil(try keychain.load(account: KeychainService.pendingAccount))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSignOutRevokesAndClearsKeychain() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()
        try service.attachEmail("alice@example.com")

        try await service.signOut()

        XCTAssertEqual(authorizer.revokeCallCount, 1)
        XCTAssertNil(service.session)
        XCTAssertNil(try keychain.load(account: "alice@example.com"))
    }

    func testSignOutClearsKeychainEvenWhenRevokeFails() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()
        authorizer.revokeError = NSError(domain: "net", code: -1009)

        try await service.signOut()

        XCTAssertNil(service.session)
        XCTAssertNil(try keychain.load(account: KeychainService.pendingAccount))
    }

    func testRestoreLoadsPendingSession() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()
        let fresh = AuthService(keychain: keychain, authorizer: authorizer, userDefaults: defaults)

        let restored = try fresh.restore()

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.accessToken, "a1")
    }

    func testRestoreEmailLoadsMigratedSession() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()
        try service.attachEmail("alice@example.com")
        let fresh = AuthService(keychain: keychain, authorizer: authorizer, userDefaults: defaults)

        let restored = try fresh.restore(email: "alice@example.com")

        XCTAssertEqual(restored?.email, "alice@example.com")
    }

    /// Regression: quitting after a complete sign-in (signIn + attachEmail) used
    /// to leave restore() returning nil because attachEmail moved the entry off
    /// `__pending__`. The fix persists the email in UserDefaults so restore()
    /// (no-args) can find the migrated entry on relaunch.
    func testRestoreFindsMigratedSessionAcrossRelaunch() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()
        try service.attachEmail("alice@example.com")

        // Simulate app quit + relaunch — fresh AuthService, same Keychain + UserDefaults.
        let fresh = AuthService(keychain: keychain, authorizer: authorizer, userDefaults: defaults)

        let restored = try fresh.restore()

        XCTAssertNotNil(restored, "restore() must find the migrated session via lastEmailDefaultsKey")
        XCTAssertEqual(restored?.accessToken, "a1")
        XCTAssertEqual(restored?.email, "alice@example.com")
    }

    func testSignOutClearsLastEmailKey() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 3600))
        _ = try await service.signIn()
        try service.attachEmail("alice@example.com")

        try await service.signOut()

        XCTAssertNil(defaults.string(forKey: AuthService.lastEmailDefaultsKey))
    }

    func testRefreshFailureClearsLastEmailKey() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 30))
        _ = try await service.signIn()
        try service.attachEmail("alice@example.com")
        clock.advance(120)
        authorizer.refreshResult = .failure(NSError(domain: "test", code: 401))

        do {
            _ = try await service.freshAccessToken()
            XCTFail("expected refresh to fail")
        } catch AppError.auth(.refreshTokenInvalid) {
            XCTAssertNil(defaults.string(forKey: AuthService.lastEmailDefaultsKey))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Waking the Mac offline must not wipe the refresh token: a network error
    /// during refresh is rethrown as-is and the session stays.
    func testRefreshNetworkErrorKeepsTokens() async throws {
        authorizer.initialResult = .success(makeSession(access: "a1", expiresIn: 30))
        _ = try await service.signIn()
        try service.attachEmail("alice@example.com")
        clock.advance(120)
        authorizer.refreshResult = .failure(AppError.network(.offline))

        do {
            _ = try await service.freshAccessToken()
            XCTFail("expected refresh to fail")
        } catch AppError.network(.offline) {
            XCTAssertNotNil(service.session)
            XCTAssertNotNil(try keychain.load(account: "alice@example.com"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFreshAccessTokenFailsWhenNotSignedIn() async {
        do {
            _ = try await service.freshAccessToken()
            XCTFail("expected error")
        } catch AppError.auth(.notSignedIn) {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeSession(access: String, expiresIn: TimeInterval, refresh: String = "r1") -> AuthSession {
        AuthSession(
            accessToken: access,
            refreshToken: refresh,
            idToken: nil,
            expiresAt: clock.now().addingTimeInterval(expiresIn),
            email: nil
        )
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(initial: Date) { current = initial }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

