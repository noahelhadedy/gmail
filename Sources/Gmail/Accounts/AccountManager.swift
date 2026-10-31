import Foundation

/// Owns one AuthService + PollingCoordinator per Google account and keeps
/// AppState.accounts in sync with the persisted AccountStore.
@MainActor
final class AccountManager {
    typealias SchedulerFactory = @MainActor () -> PollScheduling

    private let appState: AppState
    private let store: AccountStore
    private let keychain: KeychainService
    /// Nil when the build has no OAuth client ID; adding accounts is disabled.
    private let authorizer: AuthorizationPerforming?
    private let api: GmailAPIClienting
    private let notifier: PollingNotifying?
    private let userDefaults: UserDefaults
    private let makeScheduler: SchedulerFactory

    private(set) var coordinators: [String: PollingCoordinator] = [:]
    /// Sign-ins share Keychain's `__pending__` slot until the email is known,
    /// so only one may run at a time.
    private var isAddingAccount = false

    var interval: TimeInterval = 60 {
        didSet { coordinators.values.forEach { $0.interval = interval } }
    }

    init(
        appState: AppState,
        store: AccountStore,
        keychain: KeychainService,
        authorizer: AuthorizationPerforming?,
        api: GmailAPIClienting,
        notifier: PollingNotifying?,
        userDefaults: UserDefaults = .standard,
        makeScheduler: @escaping SchedulerFactory = { BackgroundActivityPollScheduler() }
    ) {
        self.appState = appState
        self.store = store
        self.keychain = keychain
        self.authorizer = authorizer
        self.api = api
        self.notifier = notifier
        self.userDefaults = userDefaults
        self.makeScheduler = makeScheduler
        appState.isConfigured = authorizer != nil
    }

    /// Rebuilds every stored account from Keychain and polls them all once.
    /// Accounts whose tokens are missing show up as needing reauthorization.
    func restoreAll() async {
        for stored in store.load() {
            let auth = makeAuthService()
            let session = try? auth.restore(email: stored.email)
            let state = AccountState(
                email: stored.email,
                colorIndex: stored.colorIndex,
                authState: session == nil ? .needsReauthorization : nil
            )
            install(state: state, auth: auth)
        }
        await forEachCoordinator { coordinator in
            await coordinator.start()
            await coordinator.performTick()
        }
    }

    /// Runs the OAuth flow, learns the account's email from the Gmail profile,
    /// then stores tokens under that email. Signing in to an account that's
    /// already listed replaces its tokens (this is how "Sign in again" works).
    @discardableResult
    func addAccount() async throws -> String {
        guard authorizer != nil else {
            throw AppError.auth(.authorizationFailed(reason: "OAuth client ID missing"))
        }
        guard !isAddingAccount else {
            throw AppError.auth(.authorizationFailed(reason: "sign-in already in progress"))
        }
        isAddingAccount = true
        defer { isAddingAccount = false }
        let auth = makeAuthService()
        let session = try await auth.signIn()
        let profile: GmailProfile
        do {
            profile = try await api.getProfile(accessToken: session.accessToken)
        } catch {
            try? keychain.delete(account: KeychainService.pendingAccount)
            throw error
        }
        // Keep the stored spelling for known accounts so Keychain lookups match.
        let existing = appState.account(for: profile.emailAddress)
        try auth.attachEmail(existing?.email ?? profile.emailAddress)

        let email: String
        if let existing, let old = coordinators[existing.email] {
            await old.stop()
            old.clearPersistedState()
            existing.reset()
            existing.authState = .signedIn(email: existing.email)
            install(state: existing, auth: auth)
            email = existing.email
        } else {
            let stored = store.add(email: profile.emailAddress)
            install(state: AccountState(email: stored.email, colorIndex: stored.colorIndex), auth: auth)
            email = stored.email
        }
        guard let coordinator = coordinators[email] else { return email }
        coordinator.clearPersistedState()
        await coordinator.start()
        await coordinator.performTick()
        return email
    }

    /// Stops polling, revokes the token (best effort), clears Keychain and
    /// per-account defaults, and forgets the account.
    func removeAccount(email: String) async {
        guard let account = appState.account(for: email) else { return }
        if let coordinator = coordinators[account.email] {
            await coordinator.stop()
            coordinator.clearPersistedState()
        }
        let auth = makeAuthService()
        if (try? auth.restore(email: account.email)) != nil {
            try? await auth.signOut()
        } else {
            try? keychain.delete(account: account.email)
        }
        coordinators[account.email] = nil
        store.remove(email: account.email)
        appState.accounts.removeAll { $0.email == account.email }
    }

    func refreshAll() async {
        await forEachCoordinator { await $0.performTick() }
    }

    func refresh(email: String) async {
        await coordinators[email]?.performTick()
    }

    func markAsRead(_ message: EmailMessage, in email: String) async {
        await coordinators[email]?.markAsRead(message)
    }

    func popoverOpened() async {
        await forEachCoordinator { await $0.popoverOpened() }
    }

    func popoverClosed() async {
        await forEachCoordinator { await $0.popoverClosed() }
    }

    func networkChanged(to state: ConnectionState) async {
        appState.connectionState = state
        for coordinator in coordinators.values {
            await coordinator.networkChanged(to: state)
        }
    }

    /// Runs the work for every account concurrently (interleaved on the main
    /// actor) and waits for all of them, so one slow account doesn't delay the rest.
    private func forEachCoordinator(_ work: @escaping @MainActor (PollingCoordinator) async -> Void) async {
        let tasks = coordinators.values.map { coordinator in
            Task { await work(coordinator) }
        }
        for task in tasks { await task.value }
    }

    private func install(state: AccountState, auth: AuthService) {
        let coordinator = PollingCoordinator(
            account: state,
            auth: auth,
            api: api,
            scheduler: makeScheduler(),
            notifier: notifier,
            userDefaults: userDefaults
        )
        coordinator.interval = interval
        coordinators[state.email] = coordinator
        if !appState.accounts.contains(where: { $0 === state }) {
            appState.accounts.append(state)
        }
    }

    private func makeAuthService() -> AuthService {
        AuthService(
            keychain: keychain,
            authorizer: authorizer ?? UnconfiguredAuthorizer(),
            userDefaults: userDefaults
        )
    }
}

/// Stand-in used when the build has no OAuth client ID. Restoring or removing
/// accounts still works; anything that talks to Google fails cleanly.
private struct UnconfiguredAuthorizer: AuthorizationPerforming {
    func performInitialAuthorization() async throws -> AuthSession {
        throw AppError.auth(.authorizationFailed(reason: "OAuth client ID missing"))
    }

    func performTokenRefresh(refreshToken: String) async throws -> AuthSession {
        throw AppError.auth(.refreshTokenInvalid)
    }

    func performRevoke(refreshToken: String) async throws {}
}
