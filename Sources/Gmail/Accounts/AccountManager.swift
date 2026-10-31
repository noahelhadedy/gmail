import Foundation

/// Everything the manager needs to run Zoho accounts. Absent when the build
/// has no Zoho OAuth client, which hides every "Add Zoho Account" entry point.
struct ZohoProviderConfig: Sendable {
    /// Used for new sign-ins (starts in the default data center).
    let signIn: AuthorizationPerforming
    /// Aborts a sign-in that is still waiting for the browser.
    let cancelSignIn: @Sendable () -> Void
    /// Token refresh / revoke for an account in a given data center.
    let makeAuthorizer: @Sendable (ZohoDataCenter) -> AuthorizationPerforming
    let makeAPI: @Sendable (ZohoDataCenter) -> ZohoAPIClienting
}

/// Owns one AuthService + poller per account (Gmail or Zoho) and keeps
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
    private let zoho: ZohoProviderConfig?
    private let notifier: PollingNotifying?
    private let userDefaults: UserDefaults
    private let makeScheduler: SchedulerFactory

    private(set) var coordinators: [String: any AccountPolling] = [:]
    /// Called after every poll tick of any account (used to refresh the
    /// automation status file).
    var onAccountsChanged: (@MainActor () -> Void)?
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
        zoho: ZohoProviderConfig? = nil,
        notifier: PollingNotifying?,
        userDefaults: UserDefaults = .standard,
        makeScheduler: @escaping SchedulerFactory = { BackgroundActivityPollScheduler() }
    ) {
        self.appState = appState
        self.store = store
        self.keychain = keychain
        self.authorizer = authorizer
        self.api = api
        self.zoho = zoho
        self.notifier = notifier
        self.userDefaults = userDefaults
        self.makeScheduler = makeScheduler
        appState.isConfigured = authorizer != nil
        appState.isZohoConfigured = zoho != nil
    }

    func cancelZohoSignIn() {
        zoho?.cancelSignIn()
    }

    /// Rebuilds every stored account from Keychain and polls them all once.
    /// Accounts whose tokens are missing show up as needing reauthorization.
    func restoreAll() async {
        for stored in store.load() {
            if stored.provider == .zoho, zoho == nil {
                // No Zoho client in this build: keep the account listed (so it
                // isn't lost) but there is nothing to poll it with.
                appState.accounts.append(AccountState(
                    email: stored.email,
                    colorIndex: stored.colorIndex,
                    authState: .needsReauthorization,
                    provider: .zoho,
                    dataCenter: stored.dataCenter
                ))
                continue
            }
            let auth = makeAuthService(provider: stored.provider, dataCenter: stored.dataCenter)
            let session = try? auth.restore(email: stored.email)
            let state = AccountState(
                email: stored.email,
                colorIndex: stored.colorIndex,
                authState: session == nil ? .needsReauthorization : nil,
                provider: stored.provider,
                dataCenter: stored.dataCenter
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
    func addAccount(mode: SignInMode = .inApp) async throws -> String {
        guard authorizer != nil else {
            throw AppError.auth(.authorizationFailed(reason: "OAuth client ID missing"))
        }
        guard !isAddingAccount else {
            throw AppError.auth(.authorizationFailed(reason: "sign-in already in progress"))
        }
        isAddingAccount = true
        defer { isAddingAccount = false }
        let auth = makeAuthService()
        let session = try await auth.signIn(mode: mode)
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

        return await activate(
            auth: auth,
            existing: existing,
            newEmail: profile.emailAddress,
            provider: .gmail,
            dataCenter: nil
        )
    }

    /// Runs the Zoho OAuth flow, learns the mailbox from the Zoho API, then
    /// stores tokens under the account's address. `loginHint` picks which of the
    /// mailbox's addresses is shown (e.g. an alias like hello@), since Zoho
    /// delivers aliases into the same inbox.
    @discardableResult
    func addZohoAccount(mode: SignInMode = .inApp, loginHint: String? = nil) async throws -> String {
        guard let zoho else {
            throw AppError.auth(.authorizationFailed(reason: "Zoho OAuth client missing"))
        }
        guard !isAddingAccount else {
            throw AppError.auth(.authorizationFailed(reason: "sign-in already in progress"))
        }
        isAddingAccount = true
        defer { isAddingAccount = false }
        let signInAuth = AuthService(
            keychain: keychain,
            authorizer: zoho.signIn,
            userDefaults: userDefaults,
            tracksLastEmail: false
        )
        let session = try await signInAuth.signIn(mode: mode)
        let dataCenter = session.dataCenter.flatMap(ZohoDataCenter.init(rawValue:)) ?? .com
        let info: ZohoAccountInfo
        do {
            info = try await zoho.makeAPI(dataCenter).getAccount(accessToken: session.accessToken)
        } catch {
            try? keychain.delete(account: KeychainService.pendingAccount)
            throw error
        }
        // Signing in again to a mailbox that is already listed (under any of its
        // addresses) replaces that entry's tokens.
        let existing = info.addresses.compactMap { appState.account(for: $0) }.first
            ?? appState.account(for: info.primaryEmail)
        let email = existing?.email ?? info.displayEmail(preferring: loginHint)
        try signInAuth.attachEmail(email)
        // Later refreshes must talk to this account's own data center.
        let auth = makeAuthService(provider: .zoho, dataCenter: dataCenter)
        _ = try auth.restore(email: email)
        return await activate(auth: auth, existing: existing, newEmail: email, provider: .zoho, dataCenter: dataCenter)
    }

    /// Installs (or replaces) the account's poller and runs its first poll.
    private func activate(
        auth: AuthService,
        existing: AccountState?,
        newEmail: String,
        provider: MailProvider,
        dataCenter: ZohoDataCenter?
    ) async -> String {
        let email: String
        if let existing {
            if let old = coordinators[existing.email] {
                await old.stop()
                old.clearPersistedState()
            }
            existing.reset()
            existing.authState = .signedIn(email: existing.email)
            install(state: existing, auth: auth)
            email = existing.email
        } else {
            let stored = store.add(email: newEmail, provider: provider, dataCenter: dataCenter)
            install(
                state: AccountState(
                    email: stored.email,
                    colorIndex: stored.colorIndex,
                    provider: provider,
                    dataCenter: dataCenter
                ),
                auth: auth
            )
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
        let auth = makeAuthService(provider: account.provider, dataCenter: account.dataCenter)
        if (try? auth.restore(email: account.email)) != nil {
            try? await auth.signOut()
        } else {
            try? keychain.delete(account: account.email)
        }
        coordinators[account.email] = nil
        store.remove(email: account.email)
        appState.accounts.removeAll { $0.email == account.email }
        onAccountsChanged?()
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
    private func forEachCoordinator(_ work: @escaping @MainActor (any AccountPolling) async -> Void) async {
        let tasks = coordinators.values.map { coordinator in
            Task { await work(coordinator) }
        }
        for task in tasks { await task.value }
    }

    private func install(state: AccountState, auth: AuthService) {
        let coordinator: any AccountPolling
        switch state.provider {
        case .gmail:
            coordinator = PollingCoordinator(
                account: state,
                auth: auth,
                api: api,
                scheduler: makeScheduler(),
                notifier: notifier,
                userDefaults: userDefaults
            )
        case .zoho:
            guard let zoho else { return }
            coordinator = ZohoPollingCoordinator(
                account: state,
                auth: auth,
                api: zoho.makeAPI(state.dataCenter ?? .com),
                scheduler: makeScheduler(),
                notifier: notifier,
                userDefaults: userDefaults
            )
        }
        coordinator.interval = interval
        coordinator.onTickFinished = { [weak self] in self?.onAccountsChanged?() }
        coordinators[state.email] = coordinator
        if !appState.accounts.contains(where: { $0 === state }) {
            appState.accounts.append(state)
        }
    }

    private func makeAuthService(provider: MailProvider = .gmail, dataCenter: ZohoDataCenter? = nil) -> AuthService {
        let performer: AuthorizationPerforming
        switch provider {
        case .gmail:
            performer = authorizer ?? UnconfiguredAuthorizer()
        case .zoho:
            performer = zoho?.makeAuthorizer(dataCenter ?? .com) ?? UnconfiguredAuthorizer()
        }
        return AuthService(
            keychain: keychain,
            authorizer: performer,
            userDefaults: userDefaults,
            tracksLastEmail: provider == .gmail
        )
    }
}

/// Stand-in used when the build has no OAuth client ID. Restoring or removing
/// accounts still works; anything that talks to Google fails cleanly.
private struct UnconfiguredAuthorizer: AuthorizationPerforming {
    func performInitialAuthorization(mode: SignInMode) async throws -> AuthSession {
        throw AppError.auth(.authorizationFailed(reason: "OAuth client ID missing"))
    }

    func performTokenRefresh(refreshToken: String) async throws -> AuthSession {
        throw AppError.auth(.refreshTokenInvalid)
    }

    func performRevoke(refreshToken: String) async throws {}
}
