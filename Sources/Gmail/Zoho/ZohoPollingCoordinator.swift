import Foundation

/// Polls one Zoho Mail inbox. Mirrors PollingCoordinator's scheduling (popover
/// pause, network pause, rate-limit backoff) but fetches with the Zoho API:
/// one `messages/view?status=unread` call per tick gives both the unread count
/// and the newest messages, and new mail is whatever wasn't unread last tick.
@MainActor
final class ZohoPollingCoordinator: AccountPolling {
    /// Visible list cap; the count itself comes from up to 200 unread.
    static let visibleMessages = 20

    private(set) var state: PollingState = .idle
    var interval: TimeInterval = 60
    var onTickFinished: (@MainActor () -> Void)?

    let account: AccountState
    private let auth: AuthService
    private let api: ZohoAPIClienting
    private let scheduler: PollScheduling
    private let notifier: PollingNotifying?
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date

    private var zohoAccountId: String?
    private var inboxFolderId: String?

    init(
        account: AccountState,
        auth: AuthService,
        api: ZohoAPIClienting,
        scheduler: PollScheduling,
        notifier: PollingNotifying? = nil,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.auth = auth
        self.api = api
        self.scheduler = scheduler
        self.notifier = notifier
        self.userDefaults = userDefaults
        self.now = now
    }

    /// Ids that were unread at the end of the last successful tick.
    static func seenIdsKey(for email: String) -> String { "zohoSeenUnreadIds.\(email.lowercased())" }

    private var seenIds: Set<String>? {
        get { (userDefaults.stringArray(forKey: Self.seenIdsKey(for: account.email))).map(Set.init) }
        set {
            if let newValue {
                userDefaults.set(Array(newValue), forKey: Self.seenIdsKey(for: account.email))
            } else {
                userDefaults.removeObject(forKey: Self.seenIdsKey(for: account.email))
            }
        }
    }

    func clearPersistedState() {
        userDefaults.removeObject(forKey: Self.seenIdsKey(for: account.email))
        zohoAccountId = nil
        inboxFolderId = nil
    }

    func start() async {
        guard auth.session != nil else {
            state = .idle
            return
        }
        await beginPolling()
    }

    func stop() async {
        state = .idle
        await scheduler.invalidate()
    }

    func popoverOpened() async {
        guard case .polling = state else { return }
        state = .paused(.popoverOpen)
        await scheduler.invalidate()
        await performTick()
    }

    func popoverClosed() async {
        guard case .paused(.popoverOpen) = state else { return }
        await tickAndReschedule()
    }

    func networkChanged(to connection: ConnectionState) async {
        switch (state, connection) {
        case (_, .offline):
            if state != .idle {
                state = .paused(.network)
                await scheduler.invalidate()
            }
        case (.paused(.network), .online):
            await tickAndReschedule()
        default:
            break
        }
    }

    func performTick() async {
        defer { onTickFinished?() }
        guard auth.session != nil else {
            account.authState = .needsReauthorization
            return
        }
        account.loadState = .loading
        do {
            let token = try await auth.freshAccessToken()
            try await refresh(token: token, notifyNew: true)
            account.loadState = .loaded
            account.lastError = nil
            account.authState = .signedIn(email: account.email)
        } catch let error as AppError {
            handle(error)
        } catch {
            account.loadState = .failed(.api(.malformedResponse))
            account.lastError = .api(.malformedResponse)
        }
    }

    /// Marks one message read in Zoho, drops it from the list right away, then
    /// re-reads the inbox so the count is authoritative.
    func markAsRead(_ message: EmailMessage) async {
        do {
            let token = try await auth.freshAccessToken()
            let (accountId, _) = try await ids(token: token)
            try await api.markAsRead(accessToken: token, accountId: accountId, messageId: message.id)
            if account.emails.contains(where: { $0.id == message.id }) {
                account.emails.removeAll { $0.id == message.id }
                account.unreadCount = max(0, account.unreadCount - 1)
            }
            try? await refresh(token: token, notifyNew: false)
        } catch let error as AppError {
            handle(error)
        } catch {
            account.lastError = .api(.malformedResponse)
        }
    }

    private func refresh(token: String, notifyNew: Bool) async throws {
        let (accountId, folderId) = try await ids(token: token)
        let unread: [EmailMessage]
        do {
            unread = try await api.listUnread(
                accessToken: token,
                accountId: accountId,
                folderId: folderId,
                limit: ZohoAPIClient.maxListLimit
            )
        } catch AppError.api(.notFound) {
            // Cached ids went stale (folder or mailbox changed): look them up again.
            zohoAccountId = nil
            inboxFolderId = nil
            throw AppError.api(.notFound)
        }
        let previous = seenIds
        let currentIds = Set(unread.map(\.id))
        if notifyNew, let previous {
            let fresh = unread.filter { !previous.contains($0.id) }
            if !fresh.isEmpty {
                let dataCenter = account.dataCenter ?? .com
                await notifier?.notifyNewMessages(fresh, account: account.email) { message in
                    ZohoWebURL.message(dataCenter: dataCenter, messageId: message.id)
                }
            }
        }
        seenIds = currentIds
        account.emails = Array(unread.prefix(Self.visibleMessages))
        account.unreadCount = unread.count
    }

    private func ids(token: String) async throws -> (accountId: String, folderId: String) {
        if let zohoAccountId, let inboxFolderId { return (zohoAccountId, inboxFolderId) }
        let info = try await api.getAccount(accessToken: token)
        let folder = try await api.inboxFolderId(accessToken: token, accountId: info.accountId)
        zohoAccountId = info.accountId
        inboxFolderId = folder
        return (info.accountId, folder)
    }

    private func beginPolling() async {
        state = .polling
        await scheduler.schedule(interval: interval) { [weak self] in
            await self?.performTick()
        }
    }

    private func tickAndReschedule() async {
        state = .polling
        await performTick()
        if case .polling = state {
            await scheduler.schedule(interval: interval) { [weak self] in
                await self?.performTick()
            }
        }
    }

    private func handle(_ error: AppError) {
        switch error {
        case .api(.unauthorized), .auth(.refreshTokenInvalid):
            account.authState = .needsReauthorization
            account.lastError = error
        case .api(.rateLimited(let retryAfter)):
            state = .backoff(until: now().addingTimeInterval(retryAfter ?? 60))
            account.lastError = error
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((retryAfter ?? 60) * 1_000_000_000))
                await self?.recoverFromBackoff()
            }
        case .network:
            state = .paused(.network)
            account.lastError = error
        default:
            account.lastError = error
        }
        account.loadState = .failed(error)
    }

    private func recoverFromBackoff() async {
        guard case .backoff = state else { return }
        await beginPolling()
    }
}
