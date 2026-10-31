import Foundation

@MainActor
final class AuthService {
    nonisolated static let lastEmailDefaultsKey = "auth.lastSignedInEmail"

    private let keychain: KeychainService
    private let authorizer: AuthorizationPerforming
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private(set) var session: AuthSession?

    init(
        keychain: KeychainService,
        authorizer: AuthorizationPerforming,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.authorizer = authorizer
        self.userDefaults = userDefaults
        self.now = now
    }

    /// Restores the most recent session from Keychain.
    ///
    /// Resolution order:
    /// 1. Last-known email (from UserDefaults), if set — covers the normal case
    ///    where `attachEmail` migrated the entry off `__pending__`.
    /// 2. The `__pending__` account — covers the edge case where the previous
    ///    run signed in but quit before the profile fetch finished.
    @discardableResult
    func restore() throws -> AuthSession? {
        if let lastEmail = userDefaults.string(forKey: Self.lastEmailDefaultsKey),
           !lastEmail.isEmpty,
           let session = try loadSession(account: lastEmail) {
            self.session = session
            return session
        }
        if let session = try loadSession(account: KeychainService.pendingAccount) {
            self.session = session
            return session
        }
        return nil
    }

    @discardableResult
    func restore(email: String) throws -> AuthSession? {
        if let session = try loadSession(account: email) {
            self.session = session
            return session
        }
        return nil
    }

    func signIn() async throws -> AuthSession {
        let session = try await authorizer.performInitialAuthorization()
        try persist(session, account: KeychainService.pendingAccount)
        self.session = session
        return session
    }

    func attachEmail(_ email: String) throws {
        guard let current = session else {
            throw AppError.auth(.notSignedIn)
        }
        let updated = current.withEmail(email)
        try keychain.migrateAccount(
            from: KeychainService.pendingAccount,
            to: email
        )
        try persist(updated, account: email)
        userDefaults.set(email, forKey: Self.lastEmailDefaultsKey)
        self.session = updated
    }

    func freshAccessToken() async throws -> String {
        guard let current = session else {
            throw AppError.auth(.notSignedIn)
        }
        if current.isAccessTokenFresh(now: now()) {
            return current.accessToken
        }
        return try await refreshAccessToken(current: current)
    }

    func signOut() async throws {
        guard let current = session else { return }
        do {
            try await authorizer.performRevoke(refreshToken: current.refreshToken)
        } catch {
            // Best-effort; clear local state regardless.
        }
        try keychain.delete(account: accountKey(for: current))
        userDefaults.removeObject(forKey: Self.lastEmailDefaultsKey)
        self.session = nil
    }

    private func refreshAccessToken(current: AuthSession) async throws -> String {
        do {
            let refreshed = try await authorizer.performTokenRefresh(
                refreshToken: current.refreshToken
            )
            let merged = AuthSession(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken.isEmpty
                    ? current.refreshToken
                    : refreshed.refreshToken,
                idToken: refreshed.idToken ?? current.idToken,
                expiresAt: refreshed.expiresAt,
                email: current.email
            )
            try persist(merged, account: accountKey(for: merged))
            self.session = merged
            return merged.accessToken
        } catch let error as AppError where error.priority == .network {
            // Offline or flaky network: keep the tokens and try again next tick.
            throw error
        } catch {
            self.session = nil
            try? keychain.delete(account: accountKey(for: current))
            userDefaults.removeObject(forKey: Self.lastEmailDefaultsKey)
            throw AppError.auth(.refreshTokenInvalid)
        }
    }

    private func persist(_ session: AuthSession, account: String) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.save(data, account: account)
    }

    private func loadSession(account: String) throws -> AuthSession? {
        guard let data = try keychain.load(account: account) else { return nil }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func accountKey(for session: AuthSession) -> String {
        session.email ?? KeychainService.pendingAccount
    }
}
